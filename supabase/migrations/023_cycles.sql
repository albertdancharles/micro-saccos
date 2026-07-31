-- 023_cycles.sql — the group finally has a financial year.
--
-- Until now money only ever flowed IN. Interest and penalties accumulated into one
-- anonymous pool figure and there was no way to say "this cycle we earned X, and
-- your share of it is Y". A SACCOS/VICOBA runs in cycles — typically twelve months
-- — and at the end distributes what it earned in proportion to what each member
-- had at risk. This migration defines the cycle and the attribution; 024 does the
-- distribution.
--
-- TIME-WEIGHTED, NOT CLOSING BALANCE. A member who deposits in month 11 must not
-- take the same share as one who carried the group from month 1. The basis is
-- member-months: each member's capital measured at every month-end in the cycle
-- and summed. `share_ratio = member basis / total basis`.
--
-- Capital is reconstructed from DATED events, never from a current balance:
--   * approved savings deposits            → reviewed_at
--   * the base (non-penalty) part of a fee → the fee submission's reviewed_at
--   * approved savings adjustments         → applied_at
-- The penalty part of a fee payment is subtracted using earnings_ledger (021),
-- because a fine is not the member's capital.
--
-- Requires 021 (earnings_ledger).

-- --------------------------------------------------------------------------
-- 1. cycles
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS cycles (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text NOT NULL,
  start_date date NOT NULL,
  end_date   date NOT NULL,
  status     text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  mode       text CHECK (mode IN ('earnings_only', 'full_shareout')),
  closed_at  timestamptz,
  closed_by  uuid REFERENCES profiles(id) ON DELETE SET NULL,
  CHECK (end_date > start_date)
);

-- Exactly one cycle can be open at a time. A partial unique index is the only way
-- to say that in the schema rather than hoping the RPCs remember.
CREATE UNIQUE INDEX IF NOT EXISTS cycles_single_open ON cycles ((status)) WHERE status = 'open';

ALTER TABLE cycles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Everyone reads cycles" ON cycles;
CREATE POLICY "Everyone reads cycles" ON cycles
  FOR SELECT USING (auth.uid() IS NOT NULL);

GRANT SELECT ON cycles TO authenticated;

-- Seed the first cycle from the group's actual history, so every existing fee,
-- deposit and repayment falls inside it rather than being stranded before cycle 1.
INSERT INTO cycles (name, start_date, end_date)
SELECT
  'Cycle 1',
  s.first_day,
  (s.first_day + INTERVAL '12 months' - INTERVAL '1 day')::date
FROM (
  SELECT COALESCE(
    least(
      (SELECT min(period)                  FROM monthly_fees),
      (SELECT min(submitted_at)::date      FROM payment_submissions),
      (SELECT min(created_at)::date        FROM profiles)
    ),
    today_eat()
  ) AS first_day
) s
WHERE NOT EXISTS (SELECT 1 FROM cycles);

-- --------------------------------------------------------------------------
-- 2. v_member_capital_events — every dated change to a member's capital.
--
--    security_invoker so it inherits the RLS of the tables underneath: a member
--    sees their own events, an admin sees everyone's.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_member_capital_events
WITH (security_invoker = true) AS
  -- Savings deposits, at the moment they were approved.
  SELECT
    ps.member_id,
    ps.amount_claimed          AS amount,
    COALESCE(ps.reviewed_at, ps.submitted_at) AS occurred_at,
    'deposit'::text            AS kind
  FROM payment_submissions ps
  WHERE ps.submission_type = 'savings_deposit' AND ps.status = 'approved'

  UNION ALL

  -- Monthly fee payments, minus the penalty portion — a fine is the group's
  -- income, not the payer's savings.
  SELECT
    ps.member_id,
    ps.amount_claimed - COALESCE(
      (SELECT SUM(el.amount) FROM earnings_ledger el
        WHERE el.submission_id = ps.id AND el.kind = 'penalty'), 0),
    COALESCE(ps.reviewed_at, ps.submitted_at),
    'fee'::text
  FROM payment_submissions ps
  WHERE ps.submission_type = 'monthly_fee' AND ps.status = 'approved'

  UNION ALL

  -- Corrective adjustments, including the negative ones a loan recovery writes.
  SELECT
    sa.target_member_id,
    sa.delta,
    COALESCE(sa.applied_at, sa.created_at),
    'adjustment'::text
  FROM savings_adjustments sa
  WHERE sa.status = 'approved';

GRANT SELECT ON v_member_capital_events TO authenticated;

-- --------------------------------------------------------------------------
-- 3. member_cycle_basis(cycle) — time-weighted member-months.
--
--    For each month-end inside the cycle, every member's capital as it stood on
--    that date; summed across the months that is the basis. Negative balances are
--    floored at zero so a member who has been overdrawn by an adjustment cannot
--    drag the denominator around.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION member_cycle_basis(p_cycle_id uuid)
RETURNS TABLE (
  member_id     uuid,
  basis         numeric,
  months        int,
  closing_capital numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH c AS (
    SELECT start_date, end_date FROM cycles WHERE id = p_cycle_id
  ),
  -- Month-end dates inside the cycle. The final point is the cycle's end_date
  -- itself, so a cycle that stops mid-month still counts that month.
  month_ends AS (
    SELECT least((date_trunc('month', d) + INTERVAL '1 month' - INTERVAL '1 day')::date,
                 (SELECT end_date FROM c)) AS as_of
    FROM c, generate_series(c.start_date, c.end_date, INTERVAL '1 month') d
  ),
  -- Active members only: someone who has exited (025) has already been settled.
  members AS (
    SELECT id FROM profiles WHERE is_active = true
  ),
  points AS (
    SELECT
      m.id AS member_id,
      me.as_of,
      greatest(COALESCE((
        SELECT SUM(e.amount)
        FROM v_member_capital_events e
        WHERE e.member_id = m.id
          AND e.occurred_at::date <= me.as_of
      ), 0), 0) AS capital
    FROM members m
    CROSS JOIN (SELECT DISTINCT as_of FROM month_ends) me
  )
  SELECT
    p.member_id,
    SUM(p.capital)                                             AS basis,
    count(*)::int                                              AS months,
    -- Capital as at the final measurement point = what they would take home if
    -- the group returns capital as well as earnings.
    max(p.capital) FILTER (WHERE p.as_of = (SELECT max(as_of) FROM month_ends)) AS closing_capital
  FROM points p
  GROUP BY p.member_id;
$$;

GRANT EXECUTE ON FUNCTION member_cycle_basis(uuid) TO authenticated;

-- --------------------------------------------------------------------------
-- 4. cycle_earnings(cycle) — what the group made, net of losses.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cycle_earnings(p_cycle_id uuid)
RETURNS TABLE (
  interest_tzs  numeric,
  penalty_tzs   numeric,
  write_off_tzs numeric,
  net_tzs       numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    COALESCE(SUM(amount) FILTER (WHERE kind = 'interest'),  0),
    COALESCE(SUM(amount) FILTER (WHERE kind = 'penalty'),   0),
    COALESCE(SUM(amount) FILTER (WHERE kind = 'write_off'), 0),
    COALESCE(SUM(amount), 0)
  FROM earnings_ledger el, cycles c
  WHERE c.id = p_cycle_id
    AND el.occurred_at::date BETWEEN c.start_date AND c.end_date;
$$;

GRANT EXECUTE ON FUNCTION cycle_earnings(uuid) TO authenticated;

-- --------------------------------------------------------------------------
-- 5. Admin: adjust the open cycle's dates (2-of-N is overkill here — no money
--    moves until close_cycle runs, which IS 2-of-N).
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION update_cycle_dates(
  p_cycle_id uuid, p_start date, p_end date, p_name text
)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_end <= p_start THEN RAISE EXCEPTION 'The cycle must end after it starts'; END IF;
  IF (SELECT status FROM cycles WHERE id = p_cycle_id) <> 'open' THEN
    RAISE EXCEPTION 'A closed cycle can no longer be edited';
  END IF;

  UPDATE cycles
     SET start_date = p_start, end_date = p_end, name = COALESCE(NULLIF(trim(p_name), ''), name)
   WHERE id = p_cycle_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'update_cycle_dates', 'cycle', p_cycle_id,
          jsonb_build_object('start_date', p_start, 'end_date', p_end));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
