-- 016_role_changes.sql — 2-of-N admin role changes.
--
-- An admin can open a request to promote a member to admin or revoke another
-- admin's role. Same governance pattern as savings/pool edits:
--   * The requester's vote does NOT auto-count toward the threshold.
--   * Two OTHER admins must approve before the role flips.
--   * The last remaining admin can never be demoted (mirrors the deletion guard).
--   * 'pending' role-change requests are exclusive per target — cancel an
--     in-flight one to open a new direction.
--
-- Notifications go to every other active admin so they can vote; the audit log
-- captures who requested, who approved, and the reason. The target also gets
-- a notification once the change applies.

CREATE TABLE IF NOT EXISTS role_change_requests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_member_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  requested_by     uuid REFERENCES profiles(id) ON DELETE SET NULL,
  change_type      text NOT NULL CHECK (change_type IN ('promote', 'demote')),
  reason           text NOT NULL,
  status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'approved', 'cancelled')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  applied_at       timestamptz
);
CREATE INDEX IF NOT EXISTS role_change_requests_status_idx
  ON role_change_requests (status, created_at DESC);

CREATE TABLE IF NOT EXISTS role_change_approvals (
  request_id  uuid NOT NULL REFERENCES role_change_requests(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, admin_id)
);

ALTER TABLE role_change_requests  ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_change_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read role-change requests" ON role_change_requests;
CREATE POLICY "Admins read role-change requests" ON role_change_requests
  FOR SELECT USING (is_admin());

DROP POLICY IF EXISTS "Admins read role-change approvals" ON role_change_approvals;
CREATE POLICY "Admins read role-change approvals" ON role_change_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON role_change_requests, role_change_approvals TO authenticated;

-- --------------------------------------------------------------------------
-- Internal: actually flip the role once the threshold is reached.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION execute_role_change(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request               role_change_requests%ROWTYPE;
  v_target_role           text;
  v_remaining_admin_count int;
  v_new_role              text;
BEGIN
  SELECT * INTO v_request FROM role_change_requests WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Role-change request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';             END IF;

  SELECT role INTO v_target_role FROM profiles WHERE id = v_request.target_member_id;
  IF v_target_role IS NULL THEN RAISE EXCEPTION 'Target member not found'; END IF;

  IF v_request.change_type = 'promote' THEN
    IF v_target_role = 'admin' THEN RAISE EXCEPTION 'Member is already an admin'; END IF;
    v_new_role := 'admin';
  ELSE  -- demote
    IF v_target_role <> 'admin' THEN RAISE EXCEPTION 'Member is not an admin'; END IF;
    -- Re-check the last-admin guard at execution time.
    SELECT count(*) INTO v_remaining_admin_count
      FROM profiles WHERE role = 'admin' AND is_active = true
        AND id <> v_request.target_member_id;
    IF v_remaining_admin_count < 1 THEN
      RAISE EXCEPTION 'Cannot revoke the last remaining admin';
    END IF;
    v_new_role := 'member';
  END IF;

  UPDATE profiles SET role = v_new_role WHERE id = v_request.target_member_id;

  UPDATE role_change_requests
     SET status = 'approved', applied_at = now()
   WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'execute_role_change', 'profile', v_request.target_member_id,
          jsonb_build_object(
            'request_id',   p_request_id,
            'change_type',  v_request.change_type,
            'new_role',     v_new_role,
            'reason',       v_request.reason
          ));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_request.target_member_id, 'role_changed',
          CASE WHEN v_request.change_type = 'promote'
               THEN 'You were promoted to admin'
               ELSE 'Your admin role was revoked'
          END,
          v_request.reason,
          jsonb_build_object(
            'request_id',  p_request_id,
            'change_type', v_request.change_type,
            'new_role',    v_new_role
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- Public: open a role-change request.
--   * Caller must be admin.
--   * For 'promote': target must currently be a non-admin member.
--   * For 'demote': target must currently be an admin AND not the last one.
--   * Requester does NOT auto-vote.
--   * No overlapping pending request for the same target.
--   * With 0 other active admins the request auto-applies so the feature
--     stays usable during single-admin transitions.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION request_role_change(
  p_target_member_id uuid,
  p_change_type      text,
  p_reason           text
)
RETURNS uuid AS $$
DECLARE
  v_request_id    uuid;
  v_target_role   text;
  v_target_name   text;
  v_admin_count   int;
  v_other_admins  int;
  v_required      int;
  v_requester     text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_change_type NOT IN ('promote', 'demote') THEN
    RAISE EXCEPTION 'Invalid change_type (use promote or demote)';
  END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every role change';
  END IF;

  SELECT role, full_name INTO v_target_role, v_target_name
    FROM profiles WHERE id = p_target_member_id;
  IF v_target_role IS NULL THEN RAISE EXCEPTION 'Member not found'; END IF;

  IF p_change_type = 'promote' THEN
    IF v_target_role = 'admin' THEN
      RAISE EXCEPTION 'Member is already an admin';
    END IF;
  ELSE  -- demote
    IF v_target_role <> 'admin' THEN
      RAISE EXCEPTION 'Member is not an admin';
    END IF;
    SELECT count(*) INTO v_admin_count
      FROM profiles WHERE role = 'admin' AND is_active = true;
    IF v_admin_count <= 1 THEN
      RAISE EXCEPTION 'Cannot revoke the last remaining admin';
    END IF;
  END IF;

  -- Block overlapping pending requests for the same target.
  IF EXISTS (
    SELECT 1 FROM role_change_requests
     WHERE target_member_id = p_target_member_id AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A pending role-change request already exists for this member';
  END IF;

  INSERT INTO role_change_requests (target_member_id, requested_by, change_type, reason)
  VALUES (p_target_member_id, auth.uid(), p_change_type, trim(p_reason))
  RETURNING id INTO v_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_role_change', 'profile', p_target_member_id,
          jsonb_build_object(
            'request_id',  v_request_id,
            'change_type', p_change_type,
            'reason',      p_reason,
            'target_name', v_target_name
          ));

  -- Notify every OTHER active admin so they can vote.
  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'role_change_requested',
         CASE WHEN p_change_type = 'promote'
              THEN 'Admin promotion requested'
              ELSE 'Admin revocation requested'
         END,
         COALESCE(v_requester, 'An admin') || ' wants to ' || p_change_type || ' ' ||
           COALESCE(v_target_name, 'a member'),
         jsonb_build_object(
           'request_id',  v_request_id,
           'target_id',   p_target_member_id,
           'change_type', p_change_type
         )
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  v_required := least(2, v_other_admins);

  IF v_required = 0 THEN
    PERFORM execute_role_change(v_request_id);
  END IF;

  RETURN v_request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- Public: another admin approves. Requester cannot approve their own request.
-- The target also cannot approve a demotion targeting themselves.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_role_change(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request      role_change_requests%ROWTYPE;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM role_change_requests WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Role-change request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed';     END IF;

  IF v_request.requested_by = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;
  IF v_request.target_member_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve a role change targeting yourself';
  END IF;

  BEGIN
    INSERT INTO role_change_approvals (request_id, admin_id)
    VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this request';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_request.requested_by;
  v_required := least(2, v_other_admins);

  SELECT count(*) INTO v_approvals FROM role_change_approvals WHERE request_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_role_change', 'profile',
            v_request.target_member_id,
            jsonb_build_object(
              'request_id', p_request_id,
              'approvals',  v_approvals,
              'required',   v_required
            ));
    RETURN;
  END IF;

  PERFORM execute_role_change(p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- Public: any admin can cancel a pending role-change request.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cancel_role_change(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request role_change_requests%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM role_change_requests WHERE id = p_request_id;
  IF v_request.id IS NULL OR v_request.status <> 'pending' THEN RETURN; END IF;

  UPDATE role_change_requests SET status = 'cancelled' WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_role_change', 'profile', v_request.target_member_id,
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
