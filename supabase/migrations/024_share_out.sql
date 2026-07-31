-- 024_share_out.sql — closing a cycle and paying everyone their share.
--
-- close_cycle() freezes the arithmetic into `distributions` rows: each member's
-- time-weighted basis, their share ratio, their slice of the group's earnings and
-- (in full_shareout mode) their capital back. SNAPSHOTTING IS THE POINT — once the
-- group has agreed a share-out, a later savings correction must not silently
-- restate what everyone was told they would receive.
--
-- Two modes:
--   earnings_only  profit is paid out, capital rolls into the next cycle. The
--                  common choice for a group that wants to keep lending.
--   full_shareout  profit AND capital go back; everyone starts the next cycle at
--                  zero. The classic VICOBA year-end.
--
-- ROUNDING uses largest-remainder: every share is floored to whole shillings and
-- the leftover shillings go to the largest fractional parts. The shares therefore
-- sum EXACTLY to the pot — no stray shilling, no member quietly short-changed.
--
-- A LOSS YEAR pays no earnings (shares are floored at zero) rather than billing
-- members for a negative share. The loss already reduced the pool when it was
-- recognised. In full_shareout mode the pool must actually cover the payout, and
-- close_cycle refuses with the shortfall if it does not — the admins then have to
-- allocate the loss explicitly (a savings or pool edit) before closing.
--
-- Requires 023.

-- --------------------------------------------------------------------------
-- 1. Schema
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS distributions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cycle_id             uuid NOT NULL REFERENCES cycles(id) ON DELETE CASCADE,
  member_id            uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  basis_amount         numeric(16,2) NOT NULL,
  share_ratio          numeric(12,10) NOT NULL,
  earnings_tzs         numeric(14,2) NOT NULL DEFAULT 0,
  capital_returned_tzs numeric(14,2) NOT NULL DEFAULT 0,
  total_payout_tzs     numeric(14,2) NOT NULL DEFAULT 0,
  status               text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid')),
  paid_at              timestamptz,
  paid_by              uuid REFERENCES profiles(id) ON DELETE SET NULL,
  proof_url            text,
  UNIQUE (cycle_id, member_id)
);
CREATE INDEX IF NOT EXISTS distributions_member_idx ON distributions (member_id);

-- 2-of-N approval to close a cycle, same shape as pool edits (015).
CREATE TABLE IF NOT EXISTS cycle_closures (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cycle_id     uuid NOT NULL REFERENCES cycles(id) ON DELETE CASCADE,
  mode         text NOT NULL CHECK (mode IN ('earnings_only', 'full_shareout')),
  reason       text NOT NULL,
  requested_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
  status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'cancelled')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  applied_at   timestamptz
);

CREATE TABLE IF NOT EXISTS cycle_closure_approvals (
  closure_id  uuid NOT NULL REFERENCES cycle_closures(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (closure_id, admin_id)
);

ALTER TABLE distributions           ENABLE ROW LEVEL SECURITY;
ALTER TABLE cycle_closures          ENABLE ROW LEVEL SECURITY;
ALTER TABLE cycle_closure_approvals ENABLE ROW LEVEL SECURITY;

-- A share-out is the group's business: everyone sees everyone's share. That is
-- the same transparency stance as the member directory (019), and it is the only
-- way members can check the split adds up.
DROP POLICY IF EXISTS "Everyone reads distributions" ON distributions;
CREATE POLICY "Everyone reads distributions" ON distributions
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Everyone reads cycle closures" ON cycle_closures;
CREATE POLICY "Everyone reads cycle closures" ON cycle_closures
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Admins read closure approvals" ON cycle_closure_approvals;
CREATE POLICY "Admins read closure approvals" ON cycle_closure_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON distributions, cycle_closures, cycle_closure_approvals TO authenticated;

-- --------------------------------------------------------------------------
-- 2. v_group_pool — a paid-out earnings share is cash leaving the group.
--
--    The CAPITAL half of a payout is not subtracted here: mark_distribution_paid
--    writes a negative savings_adjustments row for it, which this view already
--    counts. Subtracting both would take the money out twice.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_group_pool AS
SELECT
    (SELECT COALESCE(SUM(amount_claimed), 0)
       FROM payment_submissions
       WHERE submission_type = 'savings_deposit' AND status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM savings_adjustments WHERE status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM pool_adjustments    WHERE status = 'approved')
  + (SELECT COALESCE(SUM(amount), 0)
       FROM loan_recoveries)
  + (SELECT COALESCE(SUM(amount_paid), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM monthly_fees)
  + (SELECT COALESCE(SUM(interest_paid), 0)
           + COALESCE(SUM(principal_paid), 0)
           + COALESCE(SUM(penalty_collected), 0)
       FROM loan_installments)
  - (SELECT COALESCE(SUM(principal), 0)
       FROM loans             WHERE status IN ('active', 'closed', 'written_off'))
  - (SELECT COALESCE(SUM(earnings_tzs), 0)
       FROM distributions     WHERE status = 'paid')
  AS pool_balance_tzs;

-- --------------------------------------------------------------------------
-- 3. preview_cycle_close — exactly what close_cycle will write, without writing
--    it. The admin wizard renders this table before anyone votes.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION preview_cycle_close(p_cycle_id uuid, p_mode text)
RETURNS TABLE (
  member_id            uuid,
  full_name            text,
  basis_amount         numeric,
  share_ratio          numeric,
  earnings_tzs         numeric,
  capital_returned_tzs numeric,
  total_payout_tzs     numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH b AS (
    SELECT * FROM member_cycle_basis(p_cycle_id)
  ),
  totals AS (
    SELECT
      tb.total_basis,
      -- Floored to whole shillings so the largest-remainder pass below distributes
      -- an integer pot and the shares can sum to it exactly. With no basis at all
      -- nobody has a proportional claim, so the pot stays in the pool instead of
      -- the remainder pass handing shillings to members who contributed nothing.
      CASE WHEN tb.total_basis > 0
           THEN floor(greatest((SELECT net_tzs FROM cycle_earnings(p_cycle_id)), 0))
           ELSE 0 END AS pot
    FROM (SELECT COALESCE(SUM(basis), 0) AS total_basis FROM b) tb
  ),
  raw AS (
    SELECT
      b.member_id,
      b.basis,
      b.closing_capital,
      CASE WHEN t.total_basis > 0 THEN b.basis / t.total_basis ELSE 0 END AS ratio,
      CASE WHEN t.total_basis > 0 THEN t.pot * b.basis / t.total_basis ELSE 0 END AS exact_share,
      t.pot
    FROM b CROSS JOIN totals t
  ),
  -- Largest remainder: floor everyone, then hand the leftover shillings to the
  -- biggest fractional parts so the shares sum exactly to the pot.
  ranked AS (
    SELECT
      raw.*,
      floor(exact_share) AS base_share,
      row_number() OVER (ORDER BY exact_share - floor(exact_share) DESC, member_id) AS rn,
      (SELECT pot FROM totals) - (SELECT COALESCE(SUM(floor(exact_share)), 0) FROM raw) AS leftover
    FROM raw
  )
  SELECT
    r.member_id,
    p.full_name,
    r.basis,
    r.ratio,
    (r.base_share + CASE WHEN r.rn <= r.leftover THEN 1 ELSE 0 END)::numeric AS earnings_tzs,
    CASE WHEN p_mode = 'full_shareout' THEN COALESCE(r.closing_capital, 0) ELSE 0 END,
    (r.base_share + CASE WHEN r.rn <= r.leftover THEN 1 ELSE 0 END)
      + CASE WHEN p_mode = 'full_shareout' THEN COALESCE(r.closing_capital, 0) ELSE 0 END
  FROM ranked r
  JOIN profiles p ON p.id = r.member_id
  ORDER BY p.full_name;
$$;

GRANT EXECUTE ON FUNCTION preview_cycle_close(uuid, text) TO authenticated;

-- --------------------------------------------------------------------------
-- 4. Execution
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION execute_cycle_close(p_closure_id uuid)
RETURNS void AS $$
DECLARE
  v_closure  cycle_closures%ROWTYPE;
  v_cycle    cycles%ROWTYPE;
  v_pool     numeric(14,2);
  v_payout   numeric(14,2);
  v_next_end date;
BEGIN
  SELECT * INTO v_closure FROM cycle_closures WHERE id = p_closure_id FOR UPDATE;
  IF v_closure.id IS NULL          THEN RAISE EXCEPTION 'Closure request not found'; END IF;
  IF v_closure.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';         END IF;

  SELECT * INTO v_cycle FROM cycles WHERE id = v_closure.cycle_id FOR UPDATE;
  IF v_cycle.status <> 'open' THEN RAISE EXCEPTION 'This cycle is already closed'; END IF;

  -- Freeze the numbers.
  INSERT INTO distributions
    (cycle_id, member_id, basis_amount, share_ratio, earnings_tzs,
     capital_returned_tzs, total_payout_tzs)
  SELECT
    v_cycle.id, member_id, basis_amount, share_ratio, earnings_tzs,
    capital_returned_tzs, total_payout_tzs
  FROM preview_cycle_close(v_cycle.id, v_closure.mode)
  WHERE total_payout_tzs > 0;

  SELECT COALESCE(SUM(total_payout_tzs), 0) INTO v_payout
    FROM distributions WHERE cycle_id = v_cycle.id;
  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;

  IF v_payout > v_pool THEN
    RAISE EXCEPTION
      'The payout of % exceeds the pool of % (short by %). Settle outstanding loans or allocate the shortfall before closing.',
      v_payout, v_pool, v_payout - v_pool;
  END IF;

  UPDATE cycles
     SET status = 'closed', mode = v_closure.mode, closed_at = now(), closed_by = auth.uid()
   WHERE id = v_cycle.id;

  UPDATE cycle_closures SET status = 'approved', applied_at = now() WHERE id = p_closure_id;

  -- Open the next cycle immediately: the group keeps running, and every fee and
  -- deposit from tomorrow needs a cycle to belong to.
  v_next_end := ((v_cycle.end_date + 1) + INTERVAL '12 months' - INTERVAL '1 day')::date;
  INSERT INTO cycles (name, start_date, end_date)
  VALUES (
    'Cycle ' || (SELECT count(*) + 1 FROM cycles),
    v_cycle.end_date + 1,
    v_next_end
  );

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'close_cycle', 'cycle', v_cycle.id,
          jsonb_build_object(
            'mode',        v_closure.mode,
            'total_payout', v_payout,
            'members',     (SELECT count(*) FROM distributions WHERE cycle_id = v_cycle.id),
            'reason',      v_closure.reason
          ));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT d.member_id, 'share_out_ready',
         'Your share-out is ready',
         'The group closed ' || v_cycle.name || '. Your share is ' || d.total_payout_tzs || ' TZS.',
         jsonb_build_object('cycle_id', v_cycle.id, 'distribution_id', d.id)
    FROM distributions d WHERE d.cycle_id = v_cycle.id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION request_cycle_close(p_cycle_id uuid, p_mode text, p_reason text)
RETURNS uuid AS $$
DECLARE
  v_closure_id   uuid;
  v_cycle        cycles%ROWTYPE;
  v_open_loans   int;
  v_open_subs    int;
  v_requester    text;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_mode NOT IN ('earnings_only', 'full_shareout') THEN
    RAISE EXCEPTION 'Unknown share-out mode: %', p_mode;
  END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required to close a cycle';
  END IF;

  SELECT * INTO v_cycle FROM cycles WHERE id = p_cycle_id;
  IF v_cycle.id IS NULL       THEN RAISE EXCEPTION 'Cycle not found';           END IF;
  IF v_cycle.status <> 'open' THEN RAISE EXCEPTION 'This cycle is already closed'; END IF;

  -- Nothing may be in flight: a submission approved mid-close would land in a
  -- cycle whose numbers are already frozen.
  SELECT count(*) INTO v_open_subs FROM payment_submissions WHERE status = 'pending';
  IF v_open_subs > 0 THEN
    RAISE EXCEPTION 'Clear the % pending payment(s) before closing the cycle', v_open_subs;
  END IF;

  SELECT count(*) INTO v_open_loans FROM loans WHERE status IN ('pending', 'active');
  IF v_open_loans > 0 AND p_mode = 'full_shareout' THEN
    RAISE EXCEPTION
      'Cannot return everyone''s capital while % loan(s) are still out. Settle or write them off first, or close with earnings only.',
      v_open_loans;
  END IF;

  IF EXISTS (SELECT 1 FROM cycle_closures WHERE cycle_id = p_cycle_id AND status = 'pending') THEN
    RAISE EXCEPTION 'A closure request for this cycle is already open';
  END IF;

  INSERT INTO cycle_closures (cycle_id, mode, reason, requested_by)
  VALUES (p_cycle_id, p_mode, trim(p_reason), auth.uid())
  RETURNING id INTO v_closure_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_cycle_close', 'cycle', p_cycle_id,
          jsonb_build_object('closure_id', v_closure_id, 'mode', p_mode, 'reason', p_reason));

  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'cycle_close_requested',
         'Cycle close proposed',
         COALESCE(v_requester, 'An admin') || ' proposed to close ' || v_cycle.name,
         jsonb_build_object('closure_id', v_closure_id, 'cycle_id', p_cycle_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  v_required := least(2, v_other_admins);

  IF v_required = 0 THEN
    PERFORM execute_cycle_close(v_closure_id);
  END IF;

  RETURN v_closure_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION approve_cycle_close(p_closure_id uuid)
RETURNS void AS $$
DECLARE
  v_closure      cycle_closures%ROWTYPE;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_closure FROM cycle_closures WHERE id = p_closure_id FOR UPDATE;
  IF v_closure.id IS NULL          THEN RAISE EXCEPTION 'Closure request not found'; END IF;
  IF v_closure.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed'; END IF;
  IF v_closure.requested_by = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;

  BEGIN
    INSERT INTO cycle_closure_approvals (closure_id, admin_id) VALUES (p_closure_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this closure';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_closure.requested_by;
  v_required := least(2, v_other_admins);

  SELECT count(*) INTO v_approvals FROM cycle_closure_approvals WHERE closure_id = p_closure_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_cycle_close', 'cycle', v_closure.cycle_id,
            jsonb_build_object('closure_id', p_closure_id,
                               'approvals', v_approvals, 'required', v_required));
    RETURN;
  END IF;

  PERFORM execute_cycle_close(p_closure_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION cancel_cycle_close(p_closure_id uuid)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE cycle_closures SET status = 'cancelled'
   WHERE id = p_closure_id AND status = 'pending';
  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_cycle_close', 'cycle', NULL,
          jsonb_build_object('closure_id', p_closure_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. mark_distribution_paid — record the actual payout, with its M-Pesa proof.
--
--    The capital half is written back as a negative savings adjustment, so the
--    member's savings, the transparency directory and the pool all fall together
--    without any of them needing to know that a share-out happened.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION mark_distribution_paid(p_distribution_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_dist  distributions%ROWTYPE;
  v_pool  numeric(14,2);
  v_cycle text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_dist FROM distributions WHERE id = p_distribution_id FOR UPDATE;
  IF v_dist.id IS NULL          THEN RAISE EXCEPTION 'Distribution not found'; END IF;
  IF v_dist.status = 'paid'     THEN RAISE EXCEPTION 'Already paid out';       END IF;
  IF v_dist.member_id = auth.uid() THEN
    RAISE EXCEPTION 'Another admin must record your own payout';
  END IF;

  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;
  IF v_dist.total_payout_tzs > v_pool THEN
    RAISE EXCEPTION 'The pool holds only % — not enough to pay %', v_pool, v_dist.total_payout_tzs;
  END IF;

  UPDATE distributions
     SET status = 'paid', paid_at = now(), paid_by = auth.uid(), proof_url = p_proof_url
   WHERE id = p_distribution_id;

  SELECT name INTO v_cycle FROM cycles WHERE id = v_dist.cycle_id;

  IF v_dist.capital_returned_tzs > 0 THEN
    INSERT INTO savings_adjustments
      (target_member_id, requested_by, delta, reason, status, applied_at)
    VALUES (v_dist.member_id, auth.uid(), -v_dist.capital_returned_tzs,
            'Capital returned at share-out (' || COALESCE(v_cycle, 'cycle') || ')',
            'approved', now());
  END IF;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'mark_distribution_paid', 'distribution', p_distribution_id,
          jsonb_build_object(
            'member_id', v_dist.member_id,
            'earnings',  v_dist.earnings_tzs,
            'capital',   v_dist.capital_returned_tzs,
            'total',     v_dist.total_payout_tzs
          ));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_dist.member_id, 'share_out_paid', 'Share-out paid',
          v_dist.total_payout_tzs || ' TZS has been paid out to you.',
          jsonb_build_object('distribution_id', p_distribution_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
