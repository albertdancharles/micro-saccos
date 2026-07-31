-- 08_meetings.test.sql — attendance fines and the social fund (migration 030).
--
-- Two properties:
--   * A fine must land in the member's savings AND the group's earnings, so it
--     reaches the pool and the next share-out without any code that knows what a
--     fine is. The books must still balance afterwards.
--   * The social fund must stay OUT of v_group_pool. If it leaked in, every
--     member's loan ceiling would quietly rise, because the cap is a fraction of
--     the pool.

DO $$
DECLARE
  v_admin   uuid;
  v_a2      uuid;
  v_present uuid;
  v_late    uuid;
  v_absent  uuid;
  v_excused uuid;
  v_meeting uuid;
  v_total   numeric;
  v_before  numeric;
  v_req     uuid;
BEGIN
  v_admin   := tests.make_admin('Meeting Admin');
  v_a2      := tests.make_admin('Meeting Admin Two');
  v_present := tests.make_member('Meeting Present');
  v_late    := tests.make_member('Meeting Late');
  v_absent  := tests.make_member('Meeting Absent');
  v_excused := tests.make_member('Meeting Excused');

  PERFORM tests.give_savings(v_present, 100000);
  PERFORM tests.give_savings(v_late,    100000);
  PERFORM tests.give_savings(v_absent,  100000);
  PERFORM tests.give_savings(v_excused, 100000);
  PERFORM tests.assert_balanced('opening deposits');

  -- ==================================================== the register
  PERFORM tests.as_user(v_admin);
  v_meeting := record_meeting(today_eat(), 'Monthly meeting', 'Agreed the loan to X.');

  -- Everyone is marked present by default; only exceptions need touching.
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM meeting_attendance
      WHERE meeting_id = v_meeting AND status = 'present'),
    6, 'the register starts with every active member present');

  PERFORM set_attendance(v_meeting, v_late,    'late');
  PERFORM set_attendance(v_meeting, v_absent,  'absent');
  PERFORM set_attendance(v_meeting, v_excused, 'excused');
  PERFORM tests.as_owner();

  PERFORM tests.raises(
    format($q$ SELECT record_meeting(%L, 'Future meeting') $q$, today_eat() + 30),
    'a meeting cannot be recorded in the future');

  -- ==================================================== applying the fines
  v_before := tests.pool();
  PERFORM tests.as_user(v_admin);
  v_total := apply_attendance_fines(v_meeting);
  PERFORM tests.as_owner();

  -- 1,000 late + 2,000 absent. Present and excused pay nothing — which is the
  -- entire reason 'excused' is a distinct status.
  PERFORM tests.eq(v_total, 3000, 'only late and absent are fined');
  PERFORM tests.eq(
    (SELECT fine_tzs FROM meeting_attendance
      WHERE meeting_id = v_meeting AND member_id = v_excused),
    0, 'an excused member is not fined');
  PERFORM tests.eq(
    (SELECT fine_tzs FROM meeting_attendance
      WHERE meeting_id = v_meeting AND member_id = v_present),
    0, 'nor is one who attended');

  -- The fine comes out of savings…
  PERFORM tests.eq(
    (SELECT COALESCE(SUM(delta), 0) FROM savings_adjustments
      WHERE target_member_id = v_absent AND status = 'approved'),
    -2000, 'the absentee''s savings fall by the fine');

  -- …and becomes group income, so it reaches the next share-out.
  PERFORM tests.eq(
    (SELECT COALESCE(SUM(amount), 0) FROM earnings_ledger WHERE source_type = 'meeting'),
    3000, 'fines are booked as group earnings');

  -- Net effect on the pool is zero: the money was already in the pool as the
  -- members' savings; the fine only changes whose it is.
  PERFORM tests.eq(tests.pool(), v_before, 'a fine moves ownership, not cash');
  PERFORM tests.assert_balanced('attendance fines');

  -- Fines bite once.
  PERFORM tests.as_user(v_admin);
  PERFORM tests.raises(format($q$ SELECT apply_attendance_fines(%L) $q$, v_meeting),
    'fines cannot be applied to the same meeting twice');
  PERFORM tests.raises(
    format($q$ SELECT set_attendance(%L, %L, 'present') $q$, v_meeting, v_absent),
    'the register is frozen once the fines are applied');
  PERFORM tests.as_owner();

  -- A member cannot run the register.
  PERFORM tests.as_user(v_present);
  PERFORM tests.raises($q$ SELECT record_meeting(current_date, 'My meeting') $q$,
    'a member cannot record a meeting');
  PERFORM tests.as_owner();

  -- ==================================================== social fund
  PERFORM tests.eq((SELECT balance_tzs FROM v_social_fund), 0, 'the fund starts empty');

  v_before := tests.pool();
  PERFORM tests.as_user(v_admin);
  PERFORM record_social_contribution(v_present, 5000, 'monthly welfare contribution');
  PERFORM record_social_contribution(v_late,    5000, 'monthly welfare contribution');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT balance_tzs FROM v_social_fund), 10000, 'contributions build the fund');

  -- THE KEY ASSERTION: welfare money is not loanable capital. If it reached
  -- v_group_pool, every member's loan ceiling would silently rise with it.
  PERFORM tests.eq(tests.pool(), v_before, 'the social fund stays out of the loan pool');
  PERFORM tests.assert_balanced('social fund contributions');

  -- Grants are 2-of-N like every other outflow.
  PERFORM tests.as_user(v_admin);
  PERFORM tests.raises(
    format($q$ SELECT request_social_grant(%L, 999999, 'too much') $q$, v_absent),
    'a grant cannot exceed the fund');
  v_req := request_social_grant(v_absent, 6000, 'funeral costs');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT balance_tzs FROM v_social_fund), 10000,
    'requesting a grant pays out nothing');

  PERFORM tests.as_user(v_admin);
  PERFORM tests.raises(format($q$ SELECT approve_social_grant(%L) $q$, v_req),
    'the requester cannot approve their own grant');
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_a2);
  PERFORM approve_social_grant(v_req);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT balance_tzs FROM v_social_fund), 4000, 'the grant is paid');
  PERFORM tests.eq((SELECT status FROM social_fund_grant_requests WHERE id = v_req), 'approved',
    'and the request is closed');
  PERFORM tests.assert_balanced('a social fund grant');
END;
$$;
