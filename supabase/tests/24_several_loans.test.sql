-- 24_several_loans.test.sql — up to three loans at once, all settled at quarter-end (051).
--
-- What must hold:
--
--   * A member can hold three loans in progress and not a fourth.
--   * Every loan ends at the next March, June, September or December meeting. The
--     interest stays monthly; only the number of months changes.
--   * The ceiling covers everything the member owes. Checked per loan, three loans
--     would each be allowed the full ceiling.
--   * Two loans stay two loans: money paid to one does not touch the other, and every
--     total that reads "the member's loan" adds them all up.

-- A clean group for each block: the file runs in one transaction. Open loans are
-- closed too, so the "one admin stays loan-free" count starts from nothing.
CREATE FUNCTION pg_temp.fresh_group() RETURNS void AS $$
BEGIN
  PERFORM tests.as_owner();
  UPDATE profiles SET is_superadmin = false WHERE is_superadmin;
  UPDATE profiles SET is_active = false WHERE is_active;
  UPDATE loans SET status = 'closed' WHERE status IN ('pending', 'active');
END;
$$ LANGUAGE plpgsql;

-- A real loan through the real path, signed by an overseer, who is a quorum alone.
CREATE FUNCTION pg_temp.issue(p_overseer uuid, p_member uuid, p_principal numeric)
RETURNS uuid AS $$
DECLARE
  v_loan uuid;
BEGIN
  PERFORM tests.as_user(p_overseer);
  v_loan := file_loan(p_member, p_principal);
  PERFORM approve_loan(v_loan, NULL);
  PERFORM tests.as_owner();
  RETURN v_loan;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.schedule(p_loan uuid) RETURNS text AS $$
  SELECT string_agg(due_date || ':' || round(interest_due) || '+' || round(principal_due), ' '
                    ORDER BY installment_number)
    FROM loan_installments WHERE loan_id = p_loan;
$$ LANGUAGE sql;

-- ============================================================================
-- A. The term runs to the next quarter-end meeting.
-- ============================================================================
DO $$
DECLARE
  v_row   record;
  v_count int;
BEGIN
  FOR v_row IN
    SELECT * FROM (VALUES
      ('2026-09-26'::date, 3, '2026-12-26'::date),
      ('2026-10-31'::date, 2, '2026-12-26'::date),
      ('2026-11-28'::date, 1, '2026-12-26'::date),
      ('2026-12-26'::date, 3, '2027-03-27'::date),
      ('2027-01-30'::date, 2, '2027-03-27'::date),
      ('2027-02-27'::date, 1, '2027-03-27'::date),
      ('2027-03-27'::date, 3, '2027-06-26'::date),
      ('2027-04-24'::date, 2, '2027-06-26'::date),
      ('2027-05-29'::date, 1, '2027-06-26'::date),
      ('2027-06-26'::date, 3, '2027-09-25'::date),
      ('2027-07-31'::date, 2, '2027-09-25'::date),
      ('2027-08-28'::date, 1, '2027-09-25'::date)
    ) AS t(anchor, months, final_due)
  LOOP
    PERFORM tests.eq(loan_term_months(v_row.anchor)::numeric, v_row.months::numeric,
      'term of a loan issued at the meeting of ' || v_row.anchor);
    PERFORM tests.eq(
      meeting_day((v_row.anchor + (v_row.months || ' month')::interval)::date)::text,
      v_row.final_due::text,
      'final meeting of a loan issued on ' || v_row.anchor);
  END LOOP;

  -- Said without naming a date, over four years of possible recording days: the
  -- last installment is a quarter-end meeting, still in the future, at most 3 away.
  SELECT count(*) INTO v_count
    FROM generate_series('2026-01-01'::date, '2029-12-31'::date, '1 day') g
    CROSS JOIN LATERAL (SELECT last_meeting_day(g::date) AS anchor) a
    CROSS JOIN LATERAL (
      SELECT loan_term_months(a.anchor) AS months,
             meeting_day((a.anchor + (loan_term_months(a.anchor) || ' month')::interval)::date) AS final_due
    ) t
   WHERE t.months NOT BETWEEN 1 AND 3
      OR EXTRACT(MONTH FROM t.final_due)::int % 3 <> 0
      OR t.final_due <= g::date;
  PERFORM tests.eq(v_count::numeric, 0, 'every day of four years ends at a future quarter-end meeting');

  RAISE NOTICE 'term rule passed';
END $$;

-- ============================================================================
-- B. The real schedule on a real loan, including one recorded late.
-- ============================================================================
DO $$
DECLARE
  v_boss uuid;
  v_m    uuid;
  v_loan uuid;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_boss := tests.make_overseer('Sched Overseer');
  v_m    := tests.make_member('Sched Member');
  PERFORM tests.give_savings(v_m, 10000000);

  PERFORM tests.as_of('2026-10-31');
  v_loan := pg_temp.issue(v_boss, v_m, 110000);
  PERFORM tests.eq(pg_temp.schedule(v_loan),
    '2026-11-28:5500+0 2026-12-26:5500+110000', 'issued at the October meeting');

  PERFORM tests.as_of('2026-11-02');
  v_loan := pg_temp.issue(v_boss, v_m, 110000);
  PERFORM tests.eq(pg_temp.schedule(v_loan),
    '2026-11-28:5500+0 2026-12-26:5500+110000',
    'recorded two days late, it still counts from the October meeting');

  PERFORM tests.as_of('2026-11-28');
  v_loan := pg_temp.issue(v_boss, v_m, 110000);
  PERFORM tests.eq(pg_temp.schedule(v_loan),
    '2026-12-26:5500+110000', 'issued at the November meeting');
  UPDATE loans SET status = 'closed' WHERE member_id = v_m;

  PERFORM tests.as_of('2026-12-26');
  v_loan := pg_temp.issue(v_boss, v_m, 110000);
  PERFORM tests.eq(pg_temp.schedule(v_loan),
    '2027-01-30:5500+0 2027-02-27:5500+0 2027-03-27:5500+110000',
    'issued at a quarter-end meeting, it runs the full quarter');

  PERFORM tests.as_of('2027-01-05');
  v_loan := pg_temp.issue(v_boss, v_m, 110000);
  PERFORM tests.eq(pg_temp.schedule(v_loan),
    '2027-01-30:5500+0 2027-02-27:5500+0 2027-03-27:5500+110000',
    'recorded in January, it still belongs to the December meeting');

  -- The first loan follows the same rule as the others: no special case for it.
  PERFORM tests.as_of('2027-02-27');
  UPDATE loans SET status = 'closed' WHERE member_id = v_m;
  v_loan := pg_temp.issue(v_boss, v_m, 110000);
  PERFORM tests.eq(pg_temp.schedule(v_loan),
    '2027-03-27:5500+110000', 'a member''s only loan ends at quarter-end too');

  PERFORM tests.eq(
    (SELECT (details->>'months') FROM audit_log
      WHERE action = 'approve_loan' AND target_id = v_loan),
    '1', 'the audit row records the term this loan actually got');

  RAISE NOTICE 'schedule passed';
END $$;

-- ============================================================================
-- C. Three loans in progress, not four. Pending loans count.
-- ============================================================================
DO $$
DECLARE
  v_a1   uuid;
  v_m    uuid;
  v_l1   uuid;
  v_l2   uuid;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_a1 := tests.make_admin('Limit Admin');
  v_m  := tests.make_member('Limit Member');
  PERFORM tests.give_savings(v_m, 1000000);

  PERFORM tests.as_user(v_a1);
  v_l1 := file_loan(v_m, 10000);
  v_l2 := file_loan(v_m, 10000);
  PERFORM file_loan(v_m, 10000);
  PERFORM tests.raises(format($q$ SELECT file_loan(%L, 10000) $q$, v_m),
    'a fourth pending loan is refused');

  -- A rejected loan is out of progress, so its slot comes back.
  PERFORM reject_loan(v_l1, 'not agreed at the meeting');
  PERFORM file_loan(v_m, 10000);
  PERFORM tests.raises(format($q$ SELECT file_loan(%L, 10000) $q$, v_m),
    'and the slot is taken again');
  PERFORM tests.as_owner();

  -- So does a loan that has been repaid.
  UPDATE loans SET status = 'closed' WHERE id = v_l2;
  PERFORM tests.as_user(v_a1);
  PERFORM file_loan(v_m, 10000);
  PERFORM tests.as_owner();

  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM loans WHERE member_id = v_m AND status IN ('pending', 'active')),
    3, 'three in progress');

  RAISE NOTICE 'three-loan limit passed';
END $$;

-- ============================================================================
-- D. The ceiling covers everything the member owes.
-- ============================================================================
DO $$
DECLARE
  v_boss uuid;
  v_a1   uuid;
  v_a2   uuid;
  v_rich uuid;
  v_m    uuid;
  v_l1   uuid;
  v_l2   uuid;
  v_cap  numeric;
  v_msg  text;
BEGIN
  -- The contribution arm: 200,000 of savings is a ceiling of 1,000,000.
  PERFORM pg_temp.fresh_group();
  v_boss := tests.make_overseer('Cap Overseer');
  v_rich := tests.make_member('Cap Funder');
  v_m    := tests.make_member('Cap Member');
  PERFORM tests.give_savings(v_rich, 10000000);
  PERFORM tests.give_savings(v_m, 200000);

  v_l1 := pg_temp.issue(v_boss, v_m, 600000);

  PERFORM tests.as_user(v_boss);
  v_l2 := file_loan(v_m, 400001);
  BEGIN
    PERFORM approve_loan(v_l2, NULL);
    v_msg := NULL;
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
  END;
  IF v_msg IS NULL THEN
    RAISE EXCEPTION 'one shilling over the contribution ceiling should be refused';
  END IF;
  IF v_msg NOT LIKE '%already owe%' THEN
    RAISE EXCEPTION 'the refusal should say what they already owe, got: %', v_msg;
  END IF;
  PERFORM reject_loan(v_l2, 'too much');
  v_l2 := file_loan(v_m, 400000);
  PERFORM approve_loan(v_l2, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_l2), 'active',
    'exactly at the ceiling, counting the first loan, is allowed');

  -- Only what is still outstanding counts, so repaid principal makes room.
  UPDATE loans SET outstanding_principal = 100000 WHERE id = v_l1;
  v_l1 := pg_temp.issue(v_boss, v_m, 500000);
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_l1), 'active',
    'repaid principal makes room for another loan');

  -- The assets arm. The money from the block above still counts towards assets, so
  -- the cap is measured rather than assumed, and the member's savings are made large
  -- enough that it is the lower of the two.
  PERFORM pg_temp.fresh_group();
  v_boss := tests.make_overseer('Assets Overseer');
  v_m    := tests.make_member('Assets Member');
  PERFORM tests.give_savings(v_m, 3000000);
  v_cap := floor(setting('pool_loan_fraction') * (SELECT total_assets_tzs FROM v_group_assets));
  IF v_cap >= 5 * member_savings(v_m) THEN
    RAISE EXCEPTION 'fixture: the assets arm should be the lower one (cap %)', v_cap;
  END IF;

  v_l1 := pg_temp.issue(v_boss, v_m, v_cap - 1000);
  PERFORM tests.as_user(v_boss);
  v_l2 := file_loan(v_m, 1001);
  PERFORM tests.raises(format($q$ SELECT approve_loan(%L, NULL) $q$, v_l2),
    'one shilling over the assets ceiling, counting the first loan, is refused');
  PERFORM reject_loan(v_l2, 'too much');
  v_l2 := file_loan(v_m, 1000);
  PERFORM approve_loan(v_l2, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_l2), 'active',
    'exactly at the assets ceiling is allowed');

  -- Two pending loans, each fine alone, signed in step. The re-check at the last
  -- signature is what stops them landing together.
  PERFORM pg_temp.fresh_group();
  v_a1 := tests.make_admin('Step Admin One');
  v_a2 := tests.make_admin('Step Admin Two');
  v_m  := tests.make_member('Step Member');
  PERFORM tests.give_savings(v_m, 200000);      -- ceiling 1,000,000

  PERFORM tests.as_user(v_a1);
  v_l1 := file_loan(v_m, 600000);
  v_l2 := file_loan(v_m, 600000);
  PERFORM approve_loan(v_l1, NULL);
  PERFORM approve_loan(v_l2, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM approve_loan(v_l1, NULL);
  PERFORM tests.raises(format($q$ SELECT approve_loan(%L, NULL) $q$, v_l2),
    'the second loan cannot complete once the first has used the room');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_l1), 'active', 'the first went through');
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_l2), 'pending', 'the second did not');

  RAISE NOTICE 'combined ceiling passed';
END $$;

-- ============================================================================
-- E. Two loans stay two loans.
-- ============================================================================
DO $$
DECLARE
  v_boss  uuid;
  v_m     uuid;
  v_l1    uuid;
  v_l2    uuid;
  v_i1    uuid;
  v_sub   uuid;
  v_total numeric;
BEGIN
  PERFORM pg_temp.fresh_group();
  PERFORM tests.fix_loan_term(1);
  v_boss := tests.make_overseer('Two Overseer');
  v_m    := tests.make_member('Two Member');
  PERFORM tests.give_savings(v_m, 1000000);

  v_l1 := pg_temp.issue(v_boss, v_m, 300000);
  v_l2 := pg_temp.issue(v_boss, v_m, 200000);

  PERFORM tests.as_user(v_boss);
  PERFORM tests.eq(
    (SELECT active_loan_tzs FROM group_member_directory() WHERE member_id = v_m),
    500000, 'the directory shows everything they owe, not the newest loan');
  PERFORM tests.eq(
    (SELECT has_active_loan::text FROM group_member_directory() WHERE member_id = v_m),
    'true', 'and says they have a loan');
  PERFORM tests.eq(
    (SELECT locked_tzs FROM member_withdrawable(v_m)),
    100000, 'savings are locked against both loans (500,000 / 5)');
  PERFORM tests.as_owner();

  -- Clear the first loan completely: 15,000 interest + 300,000 principal.
  SELECT id INTO v_i1 FROM loan_installments WHERE loan_id = v_l1;
  UPDATE loan_installments SET penalty_rate = 0 WHERE loan_id IN (v_l1, v_l2);
  v_sub := tests.submit_payment(v_m, 'loan_installment', v_i1, 315000);
  PERFORM tests.as_user(v_boss);
  PERFORM approve_submission(v_sub, 315000);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_l1), 'closed', 'the paid loan closes');
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_l2), 'active', 'the other stays open');
  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_l2), 200000,
    'and its balance has not moved');
  PERFORM tests.eq(
    (SELECT sum(interest_paid + principal_paid) FROM loan_installments WHERE loan_id = v_l2),
    0, 'nothing was paid against it');

  PERFORM tests.as_user(v_boss);
  v_total := (SELECT active_loan_tzs FROM group_member_directory() WHERE member_id = v_m);
  PERFORM tests.as_owner();
  PERFORM tests.eq(v_total, 200000, 'the directory follows it down');

  RAISE NOTICE 'independent loans passed';
END $$;

-- ============================================================================
-- F. "One admin stays loan-free" counts people, not loans.
-- ============================================================================
DO $$
DECLARE
  v_a uuid;
  v_b uuid;
  v_c uuid;
  v_loan uuid;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_a := tests.make_admin('Free Admin A');
  v_b := tests.make_admin('Free Admin B');
  v_c := tests.make_admin('Free Admin C');
  PERFORM tests.give_savings(v_a, 1000000);
  PERFORM tests.give_savings(v_b, 1000000);
  PERFORM tests.give_savings(v_c, 1000000);

  -- A takes two loans; B and C sign.
  FOR i IN 1..2 LOOP
    PERFORM tests.as_user(v_b);
    v_loan := file_loan(v_a, 10000);
    PERFORM approve_loan(v_loan, NULL);
    PERFORM tests.as_owner();
    PERFORM tests.as_user(v_c);
    PERFORM approve_loan(v_loan, NULL);
    PERFORM tests.as_owner();
  END LOOP;

  -- B borrowing still leaves C loan-free, so it must go through. Counting LOANS,
  -- A's two look like two admins and this is refused.
  PERFORM tests.as_user(v_a);
  v_loan := file_loan(v_b, 10000);
  PERFORM approve_loan(v_loan, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_c);
  PERFORM approve_loan(v_loan, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan), 'active',
    'one admin holding two loans is still one admin');

  -- C borrowing would leave nobody loan-free.
  PERFORM tests.as_user(v_a);
  v_loan := file_loan(v_c, 10000);
  PERFORM approve_loan(v_loan, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_b);
  PERFORM tests.raises(format($q$ SELECT approve_loan(%L, NULL) $q$, v_loan),
    'the last loan-free admin still cannot borrow');
  PERFORM tests.as_owner();

  RAISE NOTICE 'loan-free admin passed';
END $$;

-- ============================================================================
-- G. Settling the month and reminders with two loans.
-- ============================================================================
DO $$
DECLARE
  v_boss uuid;
  v_m    uuid;
  v_l1   uuid;
  v_l2   uuid;
  v_result jsonb;
BEGIN
  PERFORM pg_temp.fresh_group();
  PERFORM tests.fix_loan_term(2);
  v_boss := tests.make_overseer('Sheet Overseer');
  v_m    := tests.make_member('Sheet Member');
  PERFORM tests.give_savings(v_m, 1000000);
  UPDATE profiles SET sms_opt_in = true, phone_e164 = '+255700000024' WHERE id = v_m;

  v_l1 := pg_temp.issue(v_boss, v_m, 300000);
  v_l2 := pg_temp.issue(v_boss, v_m, 200000);
  UPDATE loan_installments SET penalty_rate = 0 WHERE loan_id IN (v_l1, v_l2);
  UPDATE loan_installments SET due_date = today_eat()
   WHERE loan_id IN (v_l1, v_l2) AND installment_number = 1;

  PERFORM tests.as_user(v_boss);
  PERFORM tests.eq((SELECT count(*)::numeric FROM monthly_settlement_sheet() WHERE member_id = v_m),
    2, 'each loan has its own row');
  PERFORM tests.eq(
    (SELECT string_agg(round(loan_principal)::text, ',' ORDER BY loan_principal)
       FROM monthly_settlement_sheet() WHERE member_id = v_m),
    '200000,300000', 'the rows say which loan they belong to');
  PERFORM tests.eq(
    (SELECT count(DISTINCT loan_id)::numeric FROM monthly_settlement_sheet() WHERE member_id = v_m),
    2, 'by id as well');
  v_result := record_monthly_settlement(
    (SELECT jsonb_agg(jsonb_build_object('kind', s.kind, 'id', s.related_id))
       FROM monthly_settlement_sheet() s), 25000);
  PERFORM tests.as_owner();

  PERFORM tests.eq((v_result->>'settled_total')::numeric, 25000, '15,000 + 10,000 of interest');
  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_l1), 300000, 'no principal, first loan');
  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_l2), 200000, 'no principal, second loan');
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notifications
      WHERE recipient_id = v_m AND kind = 'settlement_recorded'),
    1, 'one message for the member, not one per loan');

  -- Reminders name the loan, because two with one amount would read the same.
  DELETE FROM notification_deliveries WHERE recipient_id = v_m;
  UPDATE loan_installments SET due_date = today_eat() + 1
   WHERE loan_id IN (v_l1, v_l2) AND installment_number = 2;
  PERFORM send_due_reminders();
  IF NOT EXISTS (SELECT 1 FROM notification_deliveries d
                  WHERE d.recipient_id = v_m AND d.body LIKE '%300,000%')
     OR NOT EXISTS (SELECT 1 FROM notification_deliveries d
                     WHERE d.recipient_id = v_m AND d.body LIKE '%200,000%') THEN
    RAISE EXCEPTION 'each reminder should name the loan it is about';
  END IF;

  RAISE NOTICE 'settlement and reminders passed';
END $$;

-- ============================================================================
-- H. A loan whose principal is overdue is at risk, however short it was.
-- ============================================================================
DO $$
DECLARE
  v_boss uuid;
  v_m    uuid;
  v_l1   uuid;
  v_l2   uuid;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_boss := tests.make_overseer('Risk Overseer');
  v_m    := tests.make_member('Risk Member');
  PERFORM tests.give_savings(v_m, 1000000);

  -- A one-month loan has only the one installment, so "two overdue installments"
  -- could never have flagged it.
  PERFORM tests.fix_loan_term(1);
  v_l1 := pg_temp.issue(v_boss, v_m, 100000);
  UPDATE loan_installments SET due_date = today_eat() - 7 WHERE loan_id = v_l1;
  PERFORM tests.as_user(v_boss);
  PERFORM tests.eq((SELECT count(*)::numeric FROM v_loan_risk WHERE loan_id = v_l1), 1,
    'a loan whose principal is overdue is at risk');
  PERFORM tests.as_owner();

  -- One missed interest payment mid-term is still not, as before.
  PERFORM tests.fix_loan_term(3);
  v_l2 := pg_temp.issue(v_boss, v_m, 100000);
  UPDATE loan_installments SET due_date = today_eat() - 7
   WHERE loan_id = v_l2 AND installment_number = 1;
  PERFORM tests.as_user(v_boss);
  PERFORM tests.eq((SELECT count(*)::numeric FROM v_loan_risk WHERE loan_id = v_l2), 0,
    'one missed interest payment is not yet a risk');
  PERFORM tests.as_owner();

  -- Settle the month pays a final row's interest and leaves its principal: still owed.
  PERFORM tests.fix_loan_term(1);
  UPDATE loans SET status = 'closed' WHERE id IN (v_l1, v_l2);
  v_l1 := pg_temp.issue(v_boss, v_m, 100000);
  UPDATE loan_installments SET penalty_rate = 0, due_date = today_eat() - 7,
         interest_paid = interest_due, status = 'partial'
   WHERE loan_id = v_l1;
  PERFORM tests.as_user(v_boss);
  PERFORM tests.eq((SELECT count(*)::numeric FROM v_loan_risk WHERE loan_id = v_l1), 1,
    'interest paid but principal not: still at risk');
  PERFORM tests.as_owner();

  -- The principal is in and only interest is late: that is not overdue principal.
  v_l2 := pg_temp.issue(v_boss, v_m, 100000);
  UPDATE loan_installments SET penalty_rate = 0, due_date = today_eat() - 7,
         principal_paid = principal_due, status = 'partial'
   WHERE loan_id = v_l2;
  PERFORM tests.as_user(v_boss);
  PERFORM tests.eq((SELECT count(*)::numeric FROM v_loan_risk WHERE loan_id = v_l2), 0,
    'principal paid, only interest late: not flagged as overdue principal');
  PERFORM tests.as_owner();

  RAISE NOTICE 'risk flag passed';
END $$;
