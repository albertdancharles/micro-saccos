-- 13_exit_not_applicant.test.sql — a former member is not a pending sign-up (040).
--
-- Both states are `is_active = false`, and the applicant RPCs used to accept
-- either. reject_pending_member is `DELETE FROM auth.users` and cascades to
-- profiles, so calling it on someone who exited destroyed exactly the history
-- that exit exists to keep. These assertions pin the distinction.

DO $$
DECLARE
  v_admin     uuid;
  v_leaver    uuid;
  v_applicant uuid;
  v_fee       uuid;
BEGIN
  v_admin  := tests.make_admin('History Admin');
  v_leaver := tests.make_member('Departed Member');

  -- Give the leaver a history, then deactivate them the way an exit does.
  v_fee := tests.give_fee(v_leaver, date_trunc('month', today_eat())::date);
  UPDATE profiles SET is_active = false WHERE id = v_leaver;

  PERFORM tests.eq(has_member_history(v_leaver)::text, 'true',
    'a member who has been charged a fee has a history');

  -- An applicant is a profile nothing has ever been recorded against. Created
  -- through the real signup trigger, then left inactive as handle_new_user does.
  v_applicant := tests.make_member('Hopeful Applicant');
  DELETE FROM monthly_fees WHERE member_id = v_applicant;
  UPDATE profiles SET is_active = false WHERE id = v_applicant;

  PERFORM tests.eq(has_member_history(v_applicant)::text, 'false',
    'a profile nothing has been recorded against has no history');

  -- ================================================= the destructive path
  PERFORM tests.as_user(v_admin);

  PERFORM tests.raises(format($q$ SELECT reject_pending_member(%L) $q$, v_leaver),
    'rejecting a former member as an applicant is refused');

  PERFORM tests.raises(format($q$ SELECT approve_member(%L) $q$, v_leaver),
    'reinstating a former member through the applicant queue is refused');

  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT count(*) FROM profiles WHERE id = v_leaver), 1,
    'the former member still exists');
  PERFORM tests.eq((SELECT count(*) FROM monthly_fees WHERE member_id = v_leaver), 1,
    'and their history is intact');
  PERFORM tests.eq((SELECT is_active FROM profiles WHERE id = v_leaver)::text, 'false',
    'and they were not silently reactivated');

  -- ================================================= a real applicant still works
  PERFORM tests.as_user(v_admin);
  PERFORM approve_member(v_applicant);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT is_active FROM profiles WHERE id = v_applicant)::text, 'true',
    'an actual applicant is still approvable');

  RAISE NOTICE 'ok — exit is not an application';
END $$;
