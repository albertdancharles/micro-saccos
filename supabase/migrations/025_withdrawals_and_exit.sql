-- 025_withdrawals_and_exit.sql — a way out that isn't deletion.
--
-- Two gaps this closes:
--
--   1. A member could deposit forever and never withdraw a shilling mid-cycle.
--   2. The only way to remove someone was request_member_deletion, which WIPES
--      their financial history — useful for an account created in error, terrible
--      for a member who simply leaves. request_member_exit settles them and
--      deactivates them, keeping every record intact.
--
-- Withdrawals get their own table rather than a fourth payment_submissions type:
-- money going OUT has a different approval shape (the proof is attached at payout,
-- by the admin, not at request time by the member) and different guards.
--
-- THE COLLATERAL GUARD is the important one. Loans are capped at
-- `contribution_multiplier x savings` (020), so savings are effectively the
-- security behind an active loan. A borrower may therefore only withdraw down to
-- `outstanding / multiplier` — withdrawing more would leave a loan the group would
-- never have approved in the first place.
--
-- Requires 024.

-- --------------------------------------------------------------------------
-- 1. Schema
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS withdrawal_requests (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  amount       numeric(12,2) NOT NULL CHECK (amount > 0),
  reason       text NOT NULL,
  status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'rejected', 'paid')),
  is_exit      boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now(),
  approved_at  timestamptz,
  paid_at      timestamptz,
  paid_by      uuid REFERENCES profiles(id) ON DELETE SET NULL,
  proof_url    text,
  rejection_reason text
);
CREATE INDEX IF NOT EXISTS withdrawal_requests_status_idx
  ON withdrawal_requests (status, created_at DESC);

CREATE TABLE IF NOT EXISTS withdrawal_approvals (
  request_id  uuid NOT NULL REFERENCES withdrawal_requests(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, admin_id)
);

ALTER TABLE withdrawal_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE withdrawal_approvals ENABLE ROW LEVEL SECURITY;

-- Withdrawals move group money, so the group sees them — same transparency stance
-- as the member directory (019) and the share-out (024).
DROP POLICY IF EXISTS "Everyone reads withdrawals" ON withdrawal_requests;
CREATE POLICY "Everyone reads withdrawals" ON withdrawal_requests
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Admins read withdrawal approvals" ON withdrawal_approvals;
CREATE POLICY "Admins read withdrawal approvals" ON withdrawal_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON withdrawal_requests, withdrawal_approvals TO authenticated;

-- --------------------------------------------------------------------------
-- 2. member_withdrawable(member) — the single source of truth for the ceiling,
--    used by the request RPC, the approval RPC and the member's own form.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION member_withdrawable(p_member_id uuid)
RETURNS TABLE (
  savings_tzs     numeric,
  outstanding_tzs numeric,
  locked_tzs      numeric,
  pool_tzs        numeric,
  withdrawable_tzs numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH s AS (
    SELECT
        COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                   WHERE member_id = p_member_id
                     AND submission_type = 'savings_deposit'
                     AND status = 'approved'), 0)
      + COALESCE((SELECT SUM(amount_paid) FROM monthly_fees
                   WHERE member_id = p_member_id), 0)
      + COALESCE((SELECT SUM(delta) FROM savings_adjustments
                   WHERE target_member_id = p_member_id AND status = 'approved'), 0)
      -- Money already committed to a withdrawal that hasn't been paid yet is not
      -- available again, or a member could drain the pool with parallel requests.
      - COALESCE((SELECT SUM(amount) FROM withdrawal_requests
                   WHERE member_id = p_member_id AND status IN ('pending', 'approved')), 0)
        AS savings,
      COALESCE((SELECT SUM(COALESCE(outstanding_principal, principal))
                  FROM loans WHERE member_id = p_member_id AND status = 'active'), 0)
        AS outstanding,
      (SELECT pool_balance_tzs FROM v_group_pool) AS pool
  )
  SELECT
    s.savings,
    s.outstanding,
    -- Savings held as security behind the active loan.
    CASE WHEN s.outstanding > 0
         THEN ceil(s.outstanding / greatest(setting('contribution_multiplier'), 1))
         ELSE 0 END,
    s.pool,
    greatest(
      least(
        s.savings - CASE WHEN s.outstanding > 0
                         THEN ceil(s.outstanding / greatest(setting('contribution_multiplier'), 1))
                         ELSE 0 END,
        s.pool
      ),
      0
    )
  FROM s;
$$;

GRANT EXECUTE ON FUNCTION member_withdrawable(uuid) TO authenticated;

-- --------------------------------------------------------------------------
-- 3. Member: open a withdrawal request.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION request_withdrawal(p_amount numeric, p_reason text)
RETURNS uuid AS $$
DECLARE
  v_id      uuid;
  v_max     numeric(14,2);
  v_name    text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND is_active = true) THEN
    RAISE EXCEPTION 'Your membership is not active';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Enter an amount greater than zero'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every withdrawal';
  END IF;

  IF EXISTS (SELECT 1 FROM withdrawal_requests
              WHERE member_id = auth.uid() AND status IN ('pending', 'approved')) THEN
    RAISE EXCEPTION 'You already have a withdrawal in progress';
  END IF;

  SELECT withdrawable_tzs INTO v_max FROM member_withdrawable(auth.uid());
  IF p_amount > v_max THEN
    RAISE EXCEPTION 'You can withdraw at most % right now', v_max;
  END IF;

  INSERT INTO withdrawal_requests (member_id, amount, reason)
  VALUES (auth.uid(), p_amount, trim(p_reason))
  RETURNING id INTO v_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_withdrawal', 'withdrawal', v_id,
          jsonb_build_object('amount', p_amount, 'reason', p_reason));

  SELECT full_name INTO v_name FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'withdrawal_requested',
         'Withdrawal requested',
         COALESCE(v_name, 'A member') || ' wants to withdraw ' || p_amount || ' TZS',
         jsonb_build_object('request_id', v_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 4. Admin: approve (2-of-N), reject, and record the payout.
--
--    Approval only authorises the payment. The money — and the member's savings —
--    move at mark_withdrawal_paid, when the M-Pesa proof exists.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_withdrawal(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_req          withdrawal_requests%ROWTYPE;
  v_max          numeric(14,2);
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_req FROM withdrawal_requests WHERE id = p_request_id FOR UPDATE;
  IF v_req.id IS NULL          THEN RAISE EXCEPTION 'Withdrawal not found';    END IF;
  IF v_req.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';       END IF;
  IF v_req.member_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own withdrawal';
  END IF;

  BEGIN
    INSERT INTO withdrawal_approvals (request_id, admin_id) VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this withdrawal';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_req.member_id;
  v_required := least(2, v_other_admins);

  SELECT count(*) INTO v_approvals FROM withdrawal_approvals WHERE request_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_withdrawal', 'withdrawal', p_request_id,
            jsonb_build_object('approvals', v_approvals, 'required', v_required));
    RETURN;
  END IF;

  -- Re-check the ceiling at the moment of approval: the pool and the member's
  -- balance may both have moved since the request was opened. The request's own
  -- amount is excluded from the "committed" subtraction inside member_withdrawable
  -- by adding it back here.
  SELECT withdrawable_tzs + v_req.amount INTO v_max FROM member_withdrawable(v_req.member_id);
  IF v_req.amount > v_max THEN
    RAISE EXCEPTION 'Only % can be withdrawn now — the pool or their balance has changed', v_max;
  END IF;

  UPDATE withdrawal_requests
     SET status = 'approved', approved_at = now()
   WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_withdrawal', 'withdrawal', p_request_id,
          jsonb_build_object('member_id', v_req.member_id, 'amount', v_req.amount));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_req.member_id, 'withdrawal_approved', 'Withdrawal approved',
          'Your withdrawal of ' || v_req.amount || ' TZS was approved and will be paid out.',
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION reject_withdrawal(p_request_id uuid, p_reason text)
RETURNS void AS $$
DECLARE
  v_req withdrawal_requests%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_req FROM withdrawal_requests WHERE id = p_request_id;
  IF v_req.id IS NULL OR v_req.status NOT IN ('pending', 'approved') THEN RETURN; END IF;

  UPDATE withdrawal_requests
     SET status = 'rejected', rejection_reason = p_reason
   WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'reject_withdrawal', 'withdrawal', p_request_id,
          jsonb_build_object('member_id', v_req.member_id, 'reason', p_reason));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_req.member_id, 'withdrawal_rejected', 'Withdrawal rejected',
          COALESCE(p_reason, 'Your withdrawal request was rejected.'),
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- The money actually leaves here. The negative savings adjustment is what makes
-- the member's balance, the transparency directory and the pool all fall together.
CREATE OR REPLACE FUNCTION mark_withdrawal_paid(p_request_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_req  withdrawal_requests%ROWTYPE;
  v_pool numeric(14,2);
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_req FROM withdrawal_requests WHERE id = p_request_id FOR UPDATE;
  IF v_req.id IS NULL           THEN RAISE EXCEPTION 'Withdrawal not found';        END IF;
  IF v_req.status <> 'approved' THEN RAISE EXCEPTION 'This withdrawal is not approved'; END IF;
  IF v_req.member_id = auth.uid() THEN
    RAISE EXCEPTION 'Another admin must record your own payout';
  END IF;

  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;
  IF v_req.amount > v_pool THEN
    RAISE EXCEPTION 'The pool holds only % — not enough to pay %', v_pool, v_req.amount;
  END IF;

  UPDATE withdrawal_requests
     SET status = 'paid', paid_at = now(), paid_by = auth.uid(), proof_url = p_proof_url
   WHERE id = p_request_id;

  INSERT INTO savings_adjustments
    (target_member_id, requested_by, delta, reason, status, applied_at)
  VALUES (v_req.member_id, auth.uid(), -v_req.amount,
          CASE WHEN v_req.is_exit THEN 'Exit settlement' ELSE 'Withdrawal' END ||
            ': ' || v_req.reason,
          'approved', now());

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'mark_withdrawal_paid', 'withdrawal', p_request_id,
          jsonb_build_object('member_id', v_req.member_id, 'amount', v_req.amount,
                             'is_exit', v_req.is_exit));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_req.member_id, 'withdrawal_paid', 'Withdrawal paid',
          v_req.amount || ' TZS has been paid out to you.',
          jsonb_build_object('request_id', p_request_id));

  -- An exit settlement is the member's last act in the group.
  IF v_req.is_exit THEN
    UPDATE profiles SET is_active = false WHERE id = v_req.member_id;
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'member_exited', 'member', v_req.member_id,
            jsonb_build_object('settlement', v_req.amount));
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. Member exit — settle and deactivate, KEEPING the history.
--
--    Deliberately distinct from request_member_deletion (010), which erases
--    everything. Exit opens a withdrawal for the member's whole remaining balance;
--    paying it out deactivates them. Every fee, loan and repayment stays on record
--    so past cycles still reconcile.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION request_member_exit(p_member_id uuid, p_reason text)
RETURNS uuid AS $$
DECLARE
  v_id          uuid;
  v_settlement  numeric(14,2);
  v_outstanding numeric(14,2);
  v_name        text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required to exit a member';
  END IF;
  IF p_member_id = auth.uid() THEN
    RAISE EXCEPTION 'Another admin must process your own exit';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_member_id AND is_active = true) THEN
    RAISE EXCEPTION 'That member is not active';
  END IF;

  -- The group cannot let someone walk away from an open loan. Settle it, write it
  -- off, or recover it from their savings first (all in 022).
  SELECT COALESCE(SUM(COALESCE(outstanding_principal, principal)), 0) INTO v_outstanding
    FROM loans WHERE member_id = p_member_id AND status IN ('pending', 'active');
  IF v_outstanding > 0 THEN
    RAISE EXCEPTION
      'This member still owes %. Settle, recover from savings, or write off the loan before they exit.',
      v_outstanding;
  END IF;

  IF EXISTS (SELECT 1 FROM withdrawal_requests
              WHERE member_id = p_member_id AND status IN ('pending', 'approved')) THEN
    RAISE EXCEPTION 'That member already has a withdrawal in progress';
  END IF;

  SELECT withdrawable_tzs INTO v_settlement FROM member_withdrawable(p_member_id);
  IF v_settlement <= 0 THEN
    RAISE EXCEPTION 'There is nothing to settle — deactivate the member instead';
  END IF;

  INSERT INTO withdrawal_requests (member_id, amount, reason, is_exit)
  VALUES (p_member_id, v_settlement, trim(p_reason), true)
  RETURNING id INTO v_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_member_exit', 'member', p_member_id,
          jsonb_build_object('request_id', v_id, 'settlement', v_settlement, 'reason', p_reason));

  SELECT full_name INTO v_name FROM profiles WHERE id = p_member_id;
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'member_exit_requested',
         'Member exit proposed',
         COALESCE(v_name, 'A member') || ' would be settled for ' || v_settlement || ' TZS and leave the group',
         jsonb_build_object('request_id', v_id, 'member_id', p_member_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
