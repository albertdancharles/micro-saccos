-- 013_savings_edits.sql — 2-of-N savings adjustments.
--
-- An admin can open a request to adjust any member's savings by a positive or
-- negative delta, BUT cannot target another admin's account. Admins MAY target
-- their own savings. The requester's own vote does NOT count toward the
-- approval threshold ("the other admins must approve"); two admins other than
-- the requester must approve before the adjustment is applied.
--
-- The pool view (v_group_pool) is extended to include applied adjustments so
-- corrections to a member's savings flow through to the group's loanable balance.
--
-- Rule summary at execution:
--   * delta is added to the target's effective savings total (a corrective entry).
--   * Audit + notification trail records who requested, who approved, and the
--     reason. The target gets a notification when the change applies.

-- --------------------------------------------------------------------------
-- 1. Schema
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS savings_adjustments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_member_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  requested_by     uuid REFERENCES profiles(id) ON DELETE SET NULL,
  delta            numeric(12,2) NOT NULL CHECK (delta <> 0),
  reason           text NOT NULL,
  status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'approved', 'cancelled')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  applied_at       timestamptz
);
CREATE INDEX IF NOT EXISTS savings_adjustments_status_idx
  ON savings_adjustments (status, created_at DESC);
CREATE INDEX IF NOT EXISTS savings_adjustments_target_idx
  ON savings_adjustments (target_member_id) WHERE status = 'approved';

CREATE TABLE IF NOT EXISTS savings_adjustment_approvals (
  adjustment_id uuid NOT NULL REFERENCES savings_adjustments(id) ON DELETE CASCADE,
  admin_id      uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (adjustment_id, admin_id)
);

ALTER TABLE savings_adjustments         ENABLE ROW LEVEL SECURITY;
ALTER TABLE savings_adjustment_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read savings adjustments" ON savings_adjustments;
CREATE POLICY "Admins read savings adjustments" ON savings_adjustments
  FOR SELECT USING (is_admin());

DROP POLICY IF EXISTS "Members read own approved savings adjustments" ON savings_adjustments;
CREATE POLICY "Members read own approved savings adjustments" ON savings_adjustments
  FOR SELECT USING (target_member_id = auth.uid() AND status = 'approved');

DROP POLICY IF EXISTS "Admins read savings approvals" ON savings_adjustment_approvals;
CREATE POLICY "Admins read savings approvals" ON savings_adjustment_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON savings_adjustments, savings_adjustment_approvals TO authenticated;

-- --------------------------------------------------------------------------
-- 2. v_group_pool — include applied savings adjustments
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_group_pool AS
SELECT
    (SELECT COALESCE(SUM(amount_claimed), 0)
       FROM payment_submissions
       WHERE submission_type = 'savings_deposit' AND status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM savings_adjustments WHERE status = 'approved')
  + (SELECT COALESCE(SUM(amount), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM monthly_fees      WHERE status = 'paid')
  + (SELECT COALESCE(SUM(total_due), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM loan_installments WHERE status = 'paid')
  - (SELECT COALESCE(SUM(principal), 0)
       FROM loans             WHERE status IN ('active', 'closed'))
  AS pool_balance_tzs;

-- --------------------------------------------------------------------------
-- 3. Internal: apply the adjustment (called once the threshold is reached).
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION execute_savings_edit(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request savings_adjustments%ROWTYPE;
BEGIN
  SELECT * INTO v_request FROM savings_adjustments WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Edit request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';     END IF;

  UPDATE savings_adjustments
     SET status = 'approved', applied_at = now()
   WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'execute_savings_edit', 'profile', v_request.target_member_id,
          jsonb_build_object(
            'request_id', p_request_id,
            'delta',      v_request.delta,
            'reason',     v_request.reason
          ));

  -- Tell the target their savings changed.
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_request.target_member_id, 'savings_edited',
          'Your savings was adjusted',
          'An admin adjustment of ' || v_request.delta || ' TZS was applied. Reason: ' ||
            v_request.reason,
          jsonb_build_object('request_id', p_request_id, 'delta', v_request.delta));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 4. Public: open a savings-edit request.
--    * Caller must be admin.
--    * Target may be a non-admin member or the caller themselves; NEVER
--      another admin.
--    * Requester does NOT auto-record an approval ("other admins must
--      approve"). With only one admin in the system the request auto-executes
--      (the feature stays usable during single-admin transitions); with 2+
--      admins it goes into the queue at 0/required.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION request_savings_edit(
  p_target_member_id uuid,
  p_delta            numeric,
  p_reason           text
)
RETURNS uuid AS $$
DECLARE
  v_request_id    uuid;
  v_target_role   text;
  v_target_name   text;
  v_requester     text;
  v_other_admins  int;
  v_required      int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_delta = 0   THEN RAISE EXCEPTION 'Delta must be non-zero'; END IF;
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every savings edit';
  END IF;

  SELECT role, full_name INTO v_target_role, v_target_name
    FROM profiles WHERE id = p_target_member_id;
  IF v_target_role IS NULL THEN RAISE EXCEPTION 'Member not found'; END IF;

  -- Admins may only target non-admins or themselves; never another admin.
  IF v_target_role = 'admin' AND p_target_member_id <> auth.uid() THEN
    RAISE EXCEPTION 'Admins cannot edit another admin''s savings';
  END IF;

  -- Block overlapping pending requests for the same target.
  IF EXISTS (
    SELECT 1 FROM savings_adjustments
     WHERE target_member_id = p_target_member_id AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A pending savings edit already exists for this member';
  END IF;

  INSERT INTO savings_adjustments (target_member_id, requested_by, delta, reason)
  VALUES (p_target_member_id, auth.uid(), p_delta, trim(p_reason))
  RETURNING id INTO v_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_savings_edit', 'profile', p_target_member_id,
          jsonb_build_object(
            'request_id',  v_request_id,
            'delta',       p_delta,
            'reason',      p_reason,
            'target_name', v_target_name
          ));

  -- Notify every other admin so they can act.
  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'savings_edit_requested',
         'Savings edit requested',
         COALESCE(v_requester, 'An admin') || ' wants to adjust ' ||
           COALESCE(v_target_name, 'a member') || '''s savings by ' ||
           p_delta || ' TZS',
         jsonb_build_object(
           'request_id', v_request_id,
           'target_id',  p_target_member_id,
           'delta',      p_delta
         )
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  -- Required = min(2, other active admin count). With a single admin in the
  -- system there are no "others" so the request auto-applies.
  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  v_required := least(2, v_other_admins);

  IF v_required = 0 THEN
    PERFORM execute_savings_edit(v_request_id);
  END IF;

  RETURN v_request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. Public: another admin approves. Reaches the threshold → execute.
--    Requester cannot approve their own request; target cannot approve.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_savings_edit(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request      savings_adjustments%ROWTYPE;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM savings_adjustments WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Edit request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed'; END IF;

  -- "Other admins must approve" — neither the requester nor the target may vote.
  IF v_request.requested_by = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;
  IF v_request.target_member_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve an edit to your own savings';
  END IF;

  BEGIN
    INSERT INTO savings_adjustment_approvals (adjustment_id, admin_id)
    VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this edit';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_request.requested_by;
  v_required := least(2, v_other_admins);

  SELECT count(*) INTO v_approvals FROM savings_adjustment_approvals WHERE adjustment_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_savings_edit', 'profile',
            v_request.target_member_id,
            jsonb_build_object(
              'request_id', p_request_id,
              'approvals',  v_approvals,
              'required',   v_required
            ));
    RETURN;
  END IF;

  PERFORM execute_savings_edit(p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 6. Public: any admin can cancel a still-pending savings edit.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cancel_savings_edit(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request savings_adjustments%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM savings_adjustments WHERE id = p_request_id;
  IF v_request.id IS NULL OR v_request.status <> 'pending' THEN
    RETURN;
  END IF;

  UPDATE savings_adjustments SET status = 'cancelled' WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_savings_edit', 'profile', v_request.target_member_id,
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
