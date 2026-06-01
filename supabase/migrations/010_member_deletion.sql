-- 010_member_deletion.sql — 2-of-N member deletion governance.
-- Mirrors the approval pattern from migration 008:
--   * An admin opens a deletion request for another member (cannot target self).
--   * Their request auto-records as their approval (1/2).
--   * A second admin approves → execute_member_deletion runs in the same
--     transaction: snapshots the member into audit_log, nulls out FK
--     references in OTHER members' history (preserves their records), deletes
--     the target's own rows (loans/installments cascade), and finally deletes
--     the auth user (which cascades to profiles → deletion_requests →
--     deletion_approvals → notifications).
-- Guard: the last remaining admin cannot be deleted, so the group never ends
-- up admin-less.

CREATE TABLE IF NOT EXISTS deletion_requests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_member_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  -- Snapshot so audit history survives even after the cascade clears the row.
  target_snapshot  jsonb,
  requested_by     uuid REFERENCES profiles(id) ON DELETE SET NULL,
  reason           text,
  status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'approved', 'cancelled')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  executed_at      timestamptz
);
CREATE INDEX IF NOT EXISTS deletion_requests_status_idx
  ON deletion_requests (status, created_at DESC);

CREATE TABLE IF NOT EXISTS deletion_approvals (
  request_id  uuid NOT NULL REFERENCES deletion_requests(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, admin_id)
);

ALTER TABLE deletion_requests  ENABLE ROW LEVEL SECURITY;
ALTER TABLE deletion_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read deletion requests" ON deletion_requests;
CREATE POLICY "Admins read deletion requests" ON deletion_requests FOR SELECT USING (is_admin());

DROP POLICY IF EXISTS "Admins read deletion approvals" ON deletion_approvals;
CREATE POLICY "Admins read deletion approvals" ON deletion_approvals FOR SELECT USING (is_admin());

GRANT SELECT ON deletion_requests, deletion_approvals TO authenticated;

-- ---------------------------------------------------------------------------
-- Internal: actually wipe the member. Called from request_/approve_ once the
-- approval threshold is reached. Marked SECURITY DEFINER so it can touch
-- auth.users; never call directly from the client.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION execute_member_deletion(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request                 deletion_requests%ROWTYPE;
  v_target_id               uuid;
  v_snapshot                jsonb;
  v_remaining_admin_count   int;
  v_target_role             text;
BEGIN
  SELECT * INTO v_request FROM deletion_requests WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Deletion request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';          END IF;

  v_target_id := v_request.target_member_id;
  v_snapshot  := v_request.target_snapshot;

  SELECT role INTO v_target_role FROM profiles WHERE id = v_target_id;
  -- Re-check the last-admin guard at execution time.
  IF v_target_role = 'admin' THEN
    SELECT count(*) INTO v_remaining_admin_count
      FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_target_id;
    IF v_remaining_admin_count < 1 THEN
      RAISE EXCEPTION 'Cannot delete the last remaining admin';
    END IF;
  END IF;

  -- Snapshot to audit_log BEFORE the cascade clears related rows.
  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'execute_member_deletion', 'profile', v_target_id,
          COALESCE(v_snapshot, '{}'::jsonb)
            || jsonb_build_object('request_id', p_request_id, 'role', v_target_role));

  -- Mark request approved BEFORE the cascade kills it.
  UPDATE deletion_requests
     SET status = 'approved', executed_at = now()
   WHERE id = p_request_id;

  -- Null out FK references in OTHER members' records (preserves their history).
  UPDATE monthly_fees        SET reviewed_by = NULL WHERE reviewed_by = v_target_id;
  UPDATE loans               SET approved_by = NULL WHERE approved_by = v_target_id;
  UPDATE payment_submissions SET reviewed_by = NULL WHERE reviewed_by = v_target_id;
  UPDATE loan_installments   SET reviewed_by = NULL WHERE reviewed_by = v_target_id;
  UPDATE audit_log           SET actor_id    = NULL WHERE actor_id    = v_target_id;
  UPDATE deletion_requests   SET requested_by = NULL WHERE requested_by = v_target_id;

  -- Clean the target's votes in approval tables (avoids FK violation on profile delete).
  DELETE FROM submission_approvals WHERE admin_id = v_target_id;
  DELETE FROM loan_approvals       WHERE admin_id = v_target_id;
  -- deletion_approvals.admin_id cascades on profile delete.

  -- Delete the target's own records. loans cascades to loan_installments and
  -- payment_submissions cascades to submission_approvals.
  DELETE FROM loans              WHERE member_id = v_target_id;
  DELETE FROM payment_submissions WHERE member_id = v_target_id;
  DELETE FROM monthly_fees       WHERE member_id = v_target_id;
  -- notifications cascades via recipient_id ON DELETE CASCADE.

  -- Finally the auth user. Cascades to profiles, and via profiles to
  -- notifications/deletion_requests/deletion_approvals (including this request).
  DELETE FROM auth.users WHERE id = v_target_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ---------------------------------------------------------------------------
-- Public: an admin opens a deletion request. Auto-records the requester's
-- approval. If only one admin is required (single-admin transition), executes
-- immediately. Notifies the other admins so they can vote.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION request_member_deletion(p_target_member_id uuid, p_reason text DEFAULT NULL)
RETURNS uuid AS $$
DECLARE
  v_request_id    uuid;
  v_target        profiles%ROWTYPE;
  v_target_email  text;
  v_admin_count   int;
  v_required      int;
  v_requester_name text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_target_member_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot request your own deletion';
  END IF;

  SELECT * INTO v_target FROM profiles WHERE id = p_target_member_id;
  IF v_target.id IS NULL THEN RAISE EXCEPTION 'Member not found'; END IF;

  -- Don't allow deleting the last remaining admin.
  IF v_target.role = 'admin' THEN
    SELECT count(*) INTO v_admin_count
      FROM profiles WHERE role = 'admin' AND is_active = true;
    IF v_admin_count <= 1 THEN
      RAISE EXCEPTION 'Cannot delete the last remaining admin';
    END IF;
  END IF;

  -- Prevent overlapping pending requests for the same target.
  IF EXISTS (
    SELECT 1 FROM deletion_requests
     WHERE target_member_id = p_target_member_id AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A pending deletion request already exists for this member';
  END IF;

  SELECT email INTO v_target_email FROM auth.users WHERE id = p_target_member_id;
  SELECT full_name INTO v_requester_name FROM profiles WHERE id = auth.uid();

  INSERT INTO deletion_requests (target_member_id, target_snapshot, requested_by, reason)
  VALUES (p_target_member_id,
          jsonb_build_object(
            'full_name',    v_target.full_name,
            'email',        v_target_email,
            'phone_number', v_target.phone_number,
            'role',         v_target.role
          ),
          auth.uid(),
          p_reason)
  RETURNING id INTO v_request_id;

  -- Auto-record requester's vote.
  INSERT INTO deletion_approvals (request_id, admin_id) VALUES (v_request_id, auth.uid());

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_member_deletion', 'profile', p_target_member_id,
          jsonb_build_object(
            'request_id', v_request_id,
            'reason',     p_reason,
            'target_name', v_target.full_name
          ));

  -- Notify every OTHER active admin so they can act.
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'deletion_requested',
         'Member deletion requested',
         COALESCE(v_requester_name, 'An admin') || ' wants to delete ' || v_target.full_name,
         jsonb_build_object(
           'request_id', v_request_id,
           'target_id',  p_target_member_id
         )
  FROM profiles p
  WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  -- If only one admin is required (single-admin transition), execute immediately.
  v_required := required_approvals();
  IF v_required <= 1 THEN
    PERFORM execute_member_deletion(v_request_id);
  END IF;

  RETURN v_request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ---------------------------------------------------------------------------
-- Public: a second admin approves. Reaches the threshold → execute.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION approve_member_deletion(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request   deletion_requests%ROWTYPE;
  v_approvals int;
  v_required  int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM deletion_requests WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Deletion request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed';   END IF;
  IF v_request.target_member_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own deletion';
  END IF;

  BEGIN
    INSERT INTO deletion_approvals (request_id, admin_id) VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this deletion';
  END;

  v_required := required_approvals();
  SELECT count(*) INTO v_approvals FROM deletion_approvals WHERE request_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_member_deletion', 'profile',
            v_request.target_member_id,
            jsonb_build_object(
              'request_id', p_request_id,
              'approvals',  v_approvals,
              'required',   v_required
            ));
    RETURN;
  END IF;

  -- Threshold reached → execute deletion.
  PERFORM execute_member_deletion(p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ---------------------------------------------------------------------------
-- Public: any admin can cancel a still-pending deletion request.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cancel_member_deletion(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request deletion_requests%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM deletion_requests WHERE id = p_request_id;
  IF v_request.id IS NULL OR v_request.status <> 'pending' THEN
    RETURN;
  END IF;

  UPDATE deletion_requests SET status = 'cancelled' WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_member_deletion', 'profile', v_request.target_member_id,
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
