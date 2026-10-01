-- 21_schedule_anchored_to_the_meeting.test.sql — a loan's schedule is counted
-- from the meeting the money was handed over at (048).
--
-- The property that matters: the FIRST INSTALLMENT IS THE VERY NEXT MEETING, no
-- matter which day of the cycle the approval is recorded on. The group lends at
-- the meeting and the admin records it afterwards, so a schedule counted from the
-- recording date skips the next meeting whenever that lag crosses no month
-- boundary at all — which is most of the time. 043 put installments on a
-- Saturday; this puts them on the right Saturday.
--
-- These tests cannot pin a literal date for the loan half, because they run on
-- whatever day CI runs and today_eat() is the input to the thing under test. So
-- they assert the relationships instead, including the one date-independent fact
-- that fails loudly against the pre-048 function: no meeting is skipped between
-- the recording and the first installment.

DO $$
DECLARE
  v_admin   uuid;
  v_a2      uuid;
  v_member  uuid;
  v_loan    uuid;
  v_today   date;
  v_anchor  date;
  v_next    date;
  v_first   date;
  v_count   int;
BEGIN
  -- ============================================== last_meeting_day() itself

  -- September 2026 met on Saturday the 26th.
  PERFORM tests.eq(last_meeting_day('2026-09-26'::date)::text, '2026-09-26',
                   'on the meeting day, the meeting is today');
  PERFORM tests.eq(last_meeting_day('2026-09-27'::date)::text, '2026-09-26',
                   'the Sunday after still belongs to that meeting');
  PERFORM tests.eq(last_meeting_day('2026-09-30'::date)::text, '2026-09-26',
                   'the last day of the month belongs to that meeting');

  -- The 1st of October is five days past the September meeting and a full month
  -- short of the October one. That is the date the September loans were recorded
  -- on, and the whole reason for the migration.
  PERFORM tests.eq(last_meeting_day('2026-10-01'::date)::text, '2026-09-26',
                   'early October still belongs to the September meeting');
  PERFORM tests.eq(last_meeting_day('2026-10-30'::date)::text, '2026-09-26',
                   'the Friday before a meeting still belongs to the last one');
  PERFORM tests.eq(last_meeting_day('2026-10-31'::date)::text, '2026-10-31',
                   'October 2026 ends on a Saturday, so the 31st is its meeting');

  -- Crossing a year end: January before its meeting looks back into December.
  PERFORM tests.eq(last_meeting_day('2027-01-05'::date)::text, '2026-12-26',
                   'early January belongs to the December meeting');

  -- Always a Saturday (DOW 6), always on or before the day asked about, and
  -- never more than five weeks back.
  SELECT count(*) INTO v_count
    FROM generate_series('2026-01-01'::date, '2029-12-31'::date, '1 day') g
   WHERE EXTRACT(DOW FROM last_meeting_day(g::date)) <> 6
      OR last_meeting_day(g::date) > g::date
      OR last_meeting_day(g::date) < g::date - 35;
  PERFORM tests.eq(v_count, 0,
    'over four years of days, the anchor is the Saturday meeting just gone');

  -- The anchor is a meeting day in its own right, so meeting_day() leaves it be.
  SELECT count(*) INTO v_count
    FROM generate_series('2026-01-01'::date, '2029-12-31'::date, '1 day') g
   WHERE last_meeting_day(g::date) <> meeting_day(last_meeting_day(g::date));
  PERFORM tests.eq(v_count, 0, 'the anchor is its own month''s meeting');

  -- ============================================== a real loan, approved today

  v_admin  := tests.make_admin('Anchor Admin');
  v_a2     := tests.make_admin('Anchor Admin Two');
  v_member := tests.make_member('Anchor Borrower');

  -- Enough savings that neither ceiling is what fails the test.
  PERFORM tests.give_savings(v_member, 2000000);

  INSERT INTO loans (member_id, principal, status)
  VALUES (v_member, 100000, 'pending')
  RETURNING id INTO v_loan;

  PERFORM tests.as_user(v_admin);
  PERFORM approve_loan(v_loan, 'test://d');
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM approve_loan(v_loan, 'test://d');
  PERFORM tests.as_owner();

  v_today  := today_eat();
  v_anchor := last_meeting_day(v_today);

  -- The next meeting still to come, computed independently of the function under
  -- test: this month's if it has not happened yet, else next month's.
  v_next := CASE WHEN meeting_day(v_today) > v_today
                 THEN meeting_day(v_today)
                 ELSE meeting_day((v_today + INTERVAL '1 month')::date) END;

  SELECT due_date INTO v_first
    FROM loan_installments WHERE loan_id = v_loan AND installment_number = 1;

  -- THE TEST. Pre-048 this was meeting_day(today + 1 month), which equals the
  -- next meeting ONLY on the handful of days of a month that fall after that
  -- month's meeting — and is a month late on every other day, the 1st included.
  PERFORM tests.eq(v_first::text, v_next::text,
    'the first installment is the next meeting, not the one after it');

  -- Said without naming a date: no meeting passes between the day the loan was
  -- recorded and the day the first repayment is asked for.
  SELECT count(*) INTO v_count
    FROM generate_series(v_today, v_first - 1, '1 day') g
   WHERE g::date = meeting_day(g::date) AND g::date > v_today;
  PERFORM tests.eq(v_count, 0,
    'no meeting passes between the approval and the first installment');

  -- And the term is counted from the hand-over: installment n is the n-th
  -- meeting after the anchor.
  SELECT count(*) INTO v_count
    FROM loan_installments
   WHERE loan_id = v_loan
     AND due_date <> meeting_day((v_anchor + (installment_number || ' month')::interval)::date);
  PERFORM tests.eq(v_count, 0, 'installment n is the n-th meeting after the anchor');

  -- 043's properties are unaffected: one installment per month, every one a
  -- meeting day, none of them born already due.
  SELECT count(DISTINCT date_trunc('month', due_date)) INTO v_count
    FROM loan_installments WHERE loan_id = v_loan;
  PERFORM tests.eq(v_count,
    (SELECT count(*)::int FROM loan_installments WHERE loan_id = v_loan),
    'installments do not double up in one month');

  SELECT count(*) INTO v_count
    FROM loan_installments
   WHERE loan_id = v_loan
     AND (due_date <> meeting_day(due_date) OR due_date <= v_today);
  PERFORM tests.eq(v_count, 0, 'every installment is a future meeting day');

  SELECT count(*) INTO v_count
    FROM v_installment_status WHERE loan_id = v_loan AND computed_status = 'overdue';
  PERFORM tests.eq(v_count, 0, 'a fresh loan has no overdue installment');

  -- The anchor is on the record, so a later question about a due date is
  -- answerable from the audit log alone.
  PERFORM tests.eq(
    (SELECT details->>'issued_at_meeting' FROM audit_log
      WHERE action = 'approve_loan' AND target_id = v_loan),
    v_anchor::text,
    'the audit row names the meeting the schedule was counted from');

  RAISE NOTICE 'schedule anchored to the meeting tests passed';
END $$;
