-- 040_exit_is_not_an_application.sql — stop the applicant queue eating ex-members.
--
-- `profiles.is_active = false` carries two entirely different meanings:
--
--   * 018 — a sign-up nobody has approved yet. handle_new_user() defaults new
--     rows to inactive, so a stray registration lands here. It has no history:
--     no fee has ever been raised against it, no shilling has ever moved.
--
--   * 025 — a member who EXITED. request_member_exit settles their whole balance
--     and mark_withdrawal_paid deactivates them. This path is deliberately
--     distinct from request_member_deletion (010), which erases: exit KEEPS every
--     fee, loan and repayment on record so past cycles still reconcile. That
--     retention is the entire point of having two flows.
--
-- Nothing distinguished them. `getAdminData` selected every inactive profile and
-- handed the lot to the applicant queue, where a member who left last quarter
-- appeared under the heading "Pending registrations", labelled "Applied <date>",
-- with two buttons:
--
--   Approve member  -> approve_member(), which flips is_active back to true. A
--                      settled, paid-out ex-member is silently a member again,
--                      back in the fee sweep, back in the share-out weighting.
--   Reject          -> reject_pending_member(), which is
--                      `DELETE FROM auth.users` and cascades to profiles. One tap
--                      destroys precisely the history exit exists to preserve —
--                      and it is the cheap-looking button, sitting next to a row
--                      that reads like a stranger's application.
--
-- The client now splits the list, but the RPCs are reachable straight from
-- PostgREST by any admin's JWT, so the rule belongs here. Both functions gain the
-- same guard: an applicant is someone with NO history. Anyone else is a former
-- member, and neither reinstatement nor erasure is an applicant decision.
--
-- Deliberately not changed: request_member_deletion (010) still deletes anyone,
-- ex-member included. That is the 2-of-N flow, it is named for what it does, and
-- an admin reaching for it has said what they mean.

-- ---------------------------------------------------------------------------
-- has_member_history — has anything ever been recorded against this profile?
--
-- An exit always books its settlement as an approved savings_adjustment, so this
-- is true even for someone who left having never paid a fee.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION has_member_history(p_member_id uuid)
RETURNS boolean AS $$
  SELECT EXISTS (SELECT 1 FROM payment_submissions WHERE member_id        = p_member_id)
      OR EXISTS (SELECT 1 FROM monthly_fees        WHERE member_id        = p_member_id)
      OR EXISTS (SELECT 1 FROM loans               WHERE member_id        = p_member_id)
      OR EXISTS (SELECT 1 FROM savings_adjustments
                  WHERE target_member_id = p_member_id AND status = 'approved');
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION has_member_history(uuid) IS
  'True once anything has been recorded against this profile. Separates a pending sign-up (018) from a member who exited (025); both are is_active = false.';

-- ---------------------------------------------------------------------------
-- approve_member — unchanged for real applicants, closed to ex-members.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION approve_member(p_member_id uuid)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  IF has_member_history(p_member_id) THEN
    RAISE EXCEPTION
      'This is a former member, not a new applicant. Their record is kept deliberately; reinstating them is not an approval.';
  END IF;

  UPDATE profiles SET is_active = true
   WHERE id = p_member_id AND is_active = false;
  IF NOT FOUND THEN RAISE EXCEPTION 'Member not found or already active'; END IF;
  INSERT INTO audit_log (actor_id, action, target_type, target_id)
  VALUES (auth.uid(), 'approve_member', 'profile', p_member_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- reject_pending_member — the destructive one. Same guard, stated in the terms
-- the admin needs: there is another flow, and it is the one that means this.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reject_pending_member(p_member_id uuid)
RETURNS void AS $$
DECLARE
  v_role   text;
  v_active boolean;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT role, is_active INTO v_role, v_active FROM profiles WHERE id = p_member_id;
  IF NOT FOUND      THEN RAISE EXCEPTION 'Member not found'; END IF;
  IF v_active       THEN RAISE EXCEPTION 'Member is already active; use member deletion instead'; END IF;
  IF v_role = 'admin' THEN RAISE EXCEPTION 'Cannot reject an admin'; END IF;

  IF has_member_history(p_member_id) THEN
    RAISE EXCEPTION
      'This member has a recorded history and cannot be rejected as an applicant. Exit keeps that history on purpose; use member deletion (2-of-N) to erase it.';
  END IF;

  INSERT INTO audit_log (actor_id, action, target_type, target_id)
  VALUES (auth.uid(), 'reject_pending_member', 'profile', p_member_id);
  DELETE FROM auth.users WHERE id = p_member_id;  -- cascades to profiles
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION has_member_history(uuid)     TO authenticated;
GRANT EXECUTE ON FUNCTION approve_member(uuid)         TO authenticated;
GRANT EXECUTE ON FUNCTION reject_pending_member(uuid)  TO authenticated;
