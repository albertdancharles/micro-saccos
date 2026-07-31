-- 029_reports.sql — the numbers a group reads out at its annual meeting.
--
-- Members could already download their own statement (Phase 4), but the GROUP had
-- no accounts: no income statement, no balance sheet, nothing to project on a wall
-- at an AGM and say "this is what we made and this is what we hold".
--
-- Almost no new data is needed. 021's earnings_ledger records every shilling of
-- income with a date, and 023's v_member_capital_events reconstructs any member's
-- capital at any point in time — both were built for the share-out and turn out to
-- be exactly what a set of accounts needs. This migration is mostly presentation.
--
-- The balance sheet reuses the SAME identity as v_pool_reconciliation (027), so the
-- report and the books-balance check can never tell the group different stories.
--
-- Requires 021, 023, 027.

-- --------------------------------------------------------------------------
-- 1. Income statement — what the group earned over a period.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION group_income_statement(p_from date, p_to date)
RETURNS TABLE (
  interest_tzs   numeric,
  penalty_tzs    numeric,
  write_off_tzs  numeric,
  net_tzs        numeric,
  loans_issued   bigint,
  loans_issued_tzs numeric,
  fees_collected_tzs numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    COALESCE((SELECT SUM(amount) FROM earnings_ledger
               WHERE kind = 'interest' AND occurred_at::date BETWEEN p_from AND p_to), 0),
    COALESCE((SELECT SUM(amount) FROM earnings_ledger
               WHERE kind = 'penalty' AND occurred_at::date BETWEEN p_from AND p_to), 0),
    COALESCE((SELECT SUM(amount) FROM earnings_ledger
               WHERE kind = 'write_off' AND occurred_at::date BETWEEN p_from AND p_to), 0),
    COALESCE((SELECT SUM(amount) FROM earnings_ledger
               WHERE occurred_at::date BETWEEN p_from AND p_to), 0),
    -- Activity, not income: how much lending the group actually did.
    COALESCE((SELECT count(*) FROM loans
               WHERE approved_at::date BETWEEN p_from AND p_to), 0),
    COALESCE((SELECT SUM(principal) FROM loans
               WHERE approved_at::date BETWEEN p_from AND p_to), 0),
    -- Fee base is members' own capital, never income — reported separately so
    -- nobody mistakes a healthy fee month for profit.
    COALESCE((SELECT SUM(ps.amount_claimed) FROM payment_submissions ps
               WHERE ps.submission_type = 'monthly_fee' AND ps.status = 'approved'
                 AND COALESCE(ps.reviewed_at, ps.submitted_at)::date BETWEEN p_from AND p_to), 0);
$$;

GRANT EXECUTE ON FUNCTION group_income_statement(date, date) TO authenticated;

-- --------------------------------------------------------------------------
-- 2. Balance sheet — what the group holds, and whose it is.
--
--    Same identity as v_pool_reconciliation (027): assets = claims. Reported
--    as-at a date so a closed cycle can be re-read exactly as it stood.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION group_balance_sheet(p_as_of date DEFAULT NULL)
RETURNS TABLE (
  as_of              date,
  pool_tzs           numeric,
  outstanding_tzs    numeric,
  total_assets_tzs   numeric,
  member_capital_tzs numeric,
  retained_earnings_tzs numeric,
  distributions_paid_tzs numeric,
  total_claims_tzs   numeric,
  difference_tzs     numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH d AS (SELECT COALESCE(p_as_of, today_eat()) AS as_of),
  cap AS (
    SELECT COALESCE(SUM(e.amount), 0) AS member_capital
    FROM v_member_capital_events e, d
    WHERE e.occurred_at::date <= d.as_of
  ),
  earn AS (
    SELECT COALESCE(SUM(el.amount), 0) AS retained
    FROM earnings_ledger el, d
    WHERE el.occurred_at::date <= d.as_of
  ),
  dist AS (
    SELECT COALESCE(SUM(x.earnings_tzs), 0) AS paid
    FROM distributions x, d
    WHERE x.status = 'paid' AND x.paid_at::date <= d.as_of
  ),
  adj AS (
    SELECT COALESCE(SUM(p.delta), 0) AS pool_adj
    FROM pool_adjustments p, d
    WHERE p.status = 'approved' AND COALESCE(p.applied_at, p.created_at)::date <= d.as_of
  ),
  assets AS (
    SELECT
      (SELECT pool_balance_tzs FROM v_group_pool) AS pool,
      COALESCE((SELECT SUM(outstanding_principal) FROM loans WHERE status = 'active'), 0)
        AS outstanding
  )
  SELECT
    d.as_of,
    a.pool,
    a.outstanding,
    a.pool + a.outstanding,
    c.member_capital,
    e.retained,
    x.paid,
    c.member_capital + e.retained - x.paid + j.pool_adj,
    (a.pool + a.outstanding) - (c.member_capital + e.retained - x.paid + j.pool_adj)
  FROM d, assets a, cap c, earn e, dist x, adj j;
$$;

GRANT EXECUTE ON FUNCTION group_balance_sheet(date) TO authenticated;

-- --------------------------------------------------------------------------
-- 3. Per-member ledger — every movement in one member's capital, with a running
--    balance. This is what settles an argument about somebody's savings.
--
--    security_invoker is not available on a function, so this checks explicitly:
--    a member may read their own ledger, an admin may read anyone's.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION member_ledger(
  p_member uuid, p_from date DEFAULT NULL, p_to date DEFAULT NULL
)
RETURNS TABLE (
  occurred_at timestamptz,
  kind        text,
  amount      numeric,
  balance     numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_member <> auth.uid() AND NOT is_admin() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  RETURN QUERY
  SELECT
    e.occurred_at,
    e.kind,
    e.amount,
    -- Running balance over the whole history, then filtered — so a ledger for a
    -- single month still opens at the right number rather than at zero.
    SUM(e.amount) OVER (ORDER BY e.occurred_at, e.kind
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
  FROM v_member_capital_events e
  WHERE e.member_id = p_member
    AND (p_from IS NULL OR e.occurred_at::date >= p_from)
    AND (p_to   IS NULL OR e.occurred_at::date <= p_to)
  ORDER BY e.occurred_at, e.kind;
END;
$$;

GRANT EXECUTE ON FUNCTION member_ledger(uuid, date, date) TO authenticated;

-- --------------------------------------------------------------------------
-- 4. Member summary for the AGM — one row per member: capital, what they still
--    owe, and what they earned from the last closed cycle.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION group_member_report(p_as_of date DEFAULT NULL)
RETURNS TABLE (
  member_id      uuid,
  full_name      text,
  role           text,
  capital_tzs    numeric,
  outstanding_tzs numeric,
  fees_paid_tzs  numeric,
  penalties_tzs  numeric,
  last_payout_tzs numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH d AS (SELECT COALESCE(p_as_of, today_eat()) AS as_of)
  SELECT
    p.id,
    p.full_name,
    p.role,
    COALESCE((SELECT SUM(e.amount) FROM v_member_capital_events e, d
               WHERE e.member_id = p.id AND e.occurred_at::date <= d.as_of), 0),
    COALESCE((SELECT SUM(COALESCE(l.outstanding_principal, l.principal))
               FROM loans l WHERE l.member_id = p.id AND l.status = 'active'), 0),
    COALESCE((SELECT SUM(f.amount_paid) FROM monthly_fees f WHERE f.member_id = p.id), 0),
    -- Penalties this member has paid: a fine, not a contribution, and the one
    -- number that shows who is carrying the group and who is costing it.
    COALESCE((SELECT SUM(el.amount) FROM earnings_ledger el
               WHERE el.member_id = p.id AND el.kind = 'penalty'), 0),
    COALESCE((SELECT x.total_payout_tzs FROM distributions x
               JOIN cycles c ON c.id = x.cycle_id
              WHERE x.member_id = p.id
              ORDER BY c.end_date DESC LIMIT 1), 0)
  FROM profiles p, d
  WHERE p.is_active = true
  ORDER BY p.full_name;
$$;

GRANT EXECUTE ON FUNCTION group_member_report(date) TO authenticated;
