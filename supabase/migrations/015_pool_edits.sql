-- 015_pool_edits.sql — 2-of-N pool/total-assets adjustments.
--
-- Total group assets = liquid pool + outstanding loans. Outstanding loans is
-- derived from active loans (not directly editable), so editing total assets
-- means adjusting the pool by a positive or negative delta. This migration
-- introduces a pool_adjustments table mirroring savings_adjustments:
--   * Any admin can open a request.
--   * The requester's vote does NOT auto-count.
--   * Two OTHER admins must approve before the delta applies.
--   * v_group_pool sums approved pool_adjustments alongside other money flows,
--     so the totals card on every dashboard reflects the change immediately.
--
-- Notifications go to every other active admin so they can vote; the audit log
-- captures who requested, who approved, and the reason.

CREATE TABLE IF NOT EXISTS pool_adjustments (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requested_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
  delta        numeric(14,2) NOT NULL CHECK (delta <> 0),
  reason       text NOT NULL,
  status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'cancelled')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  applied_at   timestamptz
);
CREATE INDEX IF NOT EXISTS pool_adjustments_status_idx
  ON pool_adjustments (status, created_at DESC);

CREATE TABLE IF NOT EXISTS pool_adjustment_approvals (
  adjustment_id uuid NOT NULL REFERENCES pool_adjustments(id) ON DELETE CASCADE,
  admin_id      uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (adjustment_id, admin_id)
);

ALTER TABLE pool_adjustments          ENABLE ROW LEVEL SECURITY;
ALTER TABLE pool_adjustment_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read pool adjustments" ON pool_adjustments;
CREATE POLICY "Admins read pool adjustments" ON pool_adjustments
  FOR SELECT USING (is_admin());

DROP POLICY IF EXISTS "Admins read pool approvals" ON pool_adjustment_approvals;
CREATE POLICY "Admins read pool approvals" ON pool_adjustment_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON pool_adjustments, pool_adjustment_approvals TO authenticated;

-- --------------------------------------------------------------------------
-- v_group_pool — include approved pool_adjustments deltas. Column structure
-- unchanged so CREATE OR REPLACE is safe; v_group_assets keeps working.
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
  + (SELECT COALESCE(SUM(amount), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM monthly_fees      WHERE status = 'paid')
  + (SELECT COALESCE(SUM(total_due), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM loan_installments WHERE status = 'paid')
  - (SELECT COALESCE(SUM(principal), 0)
       FROM loans             WHERE status IN ('active', 'closed'))
  AS pool_balance_tzs;

-- --------------------------------------------------------------------------
-- Internal: apply the adjustment once the threshold is reached.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION execute_pool_edit(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request pool_adjustments%ROWTYPE;
BEGIN
  SELECT * INTO v_request FROM pool_adjustments WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Pool edit request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';           END IF;

  UPDATE pool_adjustments
     SET status = 'approved', applied_at = now()
   WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'execute_pool_edit', 'pool', NULL,
          jsonb_build_object(
            'request_id', p_request_id,
            'delta',      v_request.delta,
            'reason',     v_request.reason
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- Public: open a pool edit request.
--   * Caller must be admin.
--   * Requester does NOT auto-record a vote — two OTHER admins must approve.
--   * With a single admin in the system the request auto-applies so the
--     feature stays usable during single-admin transitions.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION request_pool_edit(p_delta numeric, p_reason text)
RETURNS uuid AS $$
DECLARE
  v_request_id   uuid;
  v_requester    text;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_delta = 0   THEN RAISE EXCEPTION 'Delta must be non-zero'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every pool edit';
  END IF;

  -- Block overlapping pending requests so the pool doesn't get adjusted twice
  -- on the same conceptual change. Cancelling a pending request unblocks the
  -- next one.
  IF EXISTS (SELECT 1 FROM pool_adjustments WHERE status = 'pending') THEN
    RAISE EXCEPTION 'A pending pool edit already exists; cancel or approve it first';
  END IF;

  INSERT INTO pool_adjustments (requested_by, delta, reason)
  VALUES (auth.uid(), p_delta, trim(p_reason))
  RETURNING id INTO v_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_pool_edit', 'pool', NULL,
          jsonb_build_object(
            'request_id', v_request_id,
            'delta',      p_delta,
            'reason',     p_reason
          ));

  -- Notify every other active admin so they can act.
  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'pool_edit_requested',
         'Pool edit requested',
         COALESCE(v_requester, 'An admin') || ' wants to adjust the group pool by ' ||
           p_delta || ' TZS',
         jsonb_build_object(
           'request_id', v_request_id,
           'delta',      p_delta
         )
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  v_required := least(2, v_other_admins);

  IF v_required = 0 THEN
    PERFORM execute_pool_edit(v_request_id);
  END IF;

  RETURN v_request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- Public: another admin approves. Reaches the threshold → execute.
--   Requester cannot approve their own request.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_pool_edit(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request      pool_adjustments%ROWTYPE;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM pool_adjustments WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Pool edit request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed';   END IF;

  IF v_request.requested_by = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;

  BEGIN
    INSERT INTO pool_adjustment_approvals (adjustment_id, admin_id)
    VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this edit';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_request.requested_by;
  v_required := least(2, v_other_admins);

  SELECT count(*) INTO v_approvals FROM pool_adjustment_approvals WHERE adjustment_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_pool_edit', 'pool', NULL,
            jsonb_build_object(
              'request_id', p_request_id,
              'approvals',  v_approvals,
              'required',   v_required
            ));
    RETURN;
  END IF;

  PERFORM execute_pool_edit(p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- Public: any admin can cancel a pending pool edit.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cancel_pool_edit(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request pool_adjustments%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM pool_adjustments WHERE id = p_request_id;
  IF v_request.id IS NULL OR v_request.status <> 'pending' THEN RETURN; END IF;

  UPDATE pool_adjustments SET status = 'cancelled' WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_pool_edit', 'pool', NULL,
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
