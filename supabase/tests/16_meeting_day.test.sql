-- 16_meeting_day.test.sql — loan installments fall due on meeting days (043).
--
-- The property that matters: a member can only pay at the monthly meeting, so an
-- installment must never be marked overdue on a date when no meeting has yet
-- given them the chance to pay. Before 043 the due date was the approval's
-- day-of-month, which drifts off the last-Saturday meeting and put roughly a
-- third of installments days ahead of the meeting — each one costing a full
-- month's penalty for nothing.

DO $$
DECLARE
  v_admin  uuid;
  v_a2     uuid;
  v_member uuid;
  v_loan   uuid;
  r        record;
  v_count  int;
BEGIN
  -- ============================================== meeting_day() itself

  -- A month ending mid-week steps back to its last Saturday.
  PERFORM tests.eq(meeting_day('2026-09-01'::date)::text, '2026-09-26', 'Sept 2026 meeting');
  PERFORM tests.eq(meeting_day('2026-09-30'::date)::text, '2026-09-26', 'any day in Sept gives the same meeting');

  -- A month that ends ON a Saturday is its own meeting day.
  PERFORM tests.eq(meeting_day('2026-10-10'::date)::text, '2026-10-31', 'Oct 2026 ends on a Saturday');

  -- February, including a leap year.
  PERFORM tests.eq(meeting_day('2027-02-10'::date)::text, '2027-02-27', 'Feb 2027 meeting');
  PERFORM tests.eq(meeting_day('2028-02-10'::date)::text, '2028-02-26', 'Feb 2028 (leap) meeting');

  -- Whatever the month, it is always a Saturday (DOW 6).
  SELECT count(*) INTO v_count
    FROM generate_series('2026-01-01'::date, '2029-12-01'::date, '1 month') g
   WHERE EXTRACT(DOW FROM meeting_day(g::date)) <> 6;
  PERFORM tests.eq(v_count, 0, 'every meeting day over four years is a Saturday');

  -- ...and it is always in the month asked for, never the one before or after.
  SELECT count(*) INTO v_count
    FROM generate_series('2026-01-01'::date, '2029-12-01'::date, '1 month') g
   WHERE date_trunc('month', meeting_day(g::date)) <> date_trunc('month', g);
  PERFORM tests.eq(v_count, 0, 'every meeting day is inside its own month');

  -- ============================================== a real loan

  v_admin  := tests.make_admin('Meeting Day Admin');
  v_a2     := tests.make_admin('Meeting Day Admin Two');
  v_member := tests.make_member('Meeting Day Borrower');

  -- Enough savings that the 5x contribution cap is not what fails the test.
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

  -- Every installment lands on a Saturday...
  SELECT count(*) INTO v_count
    FROM loan_installments
   WHERE loan_id = v_loan AND EXTRACT(DOW FROM due_date) <> 6;
  PERFORM tests.eq(v_count, 0, 'every installment falls on a Saturday');

  -- ...and specifically on its month's meeting, not merely any Saturday.
  SELECT count(*) INTO v_count
    FROM loan_installments
   WHERE loan_id = v_loan AND due_date <> meeting_day(due_date);
  PERFORM tests.eq(v_count, 0, 'every installment falls on its month''s meeting');

  -- One installment per month, still, and all in the future.
  SELECT count(DISTINCT date_trunc('month', due_date)) INTO v_count
    FROM loan_installments WHERE loan_id = v_loan;
  PERFORM tests.eq(
    v_count,
    (SELECT count(*)::int FROM loan_installments WHERE loan_id = v_loan),
    'installments do not double up in one month'
  );

  SELECT count(*) INTO v_count
    FROM loan_installments WHERE loan_id = v_loan AND due_date <= today_eat();
  PERFORM tests.eq(v_count, 0, 'no installment is born already due');

  -- THE POINT: nothing is overdue the day it is created, and the first
  -- installment is not overdue before its own meeting has happened.
  SELECT count(*) INTO v_count
    FROM v_installment_status WHERE loan_id = v_loan AND computed_status = 'overdue';
  PERFORM tests.eq(v_count, 0, 'a fresh loan has no overdue installment');

  RAISE NOTICE 'meeting day / due date tests passed';
END $$;
