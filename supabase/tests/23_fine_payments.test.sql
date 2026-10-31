-- 23_fine_payments.test.sql — a fine handed over in cash at the meeting (050).
--
-- The rule these tests exist for, in the group's words: a fine goes straight into the
-- group's money so it can be lent to members, and it NEVER adds to anybody's savings.
--
-- So every block asserts both halves. "The pool rose" alone would also pass if the
-- fine had been booked as a savings deposit, and that is the mistake that matters: the
-- member would then own the fine they paid, and could borrow five times against it.

-- ============================================================================
-- A. Another member's fine: one signature, into the pool, not into their savings.
-- ============================================================================
DO $$
DECLARE
  v_admin   uuid;
  v_a2      uuid;
  v_m       uuid;
  v_sub     uuid;
  v_pool    numeric;
  v_assets  numeric;
  v_earn    numeric;
  v_capital numeric;
  v_events  numeric;
BEGIN
  v_admin := tests.make_admin('FineA Admin');
  v_a2    := tests.make_admin('FineA Admin Two');
  v_m     := tests.make_member('FineA Member');

  PERFORM tests.give_savings(v_m, 100000);
  UPDATE group_settings SET value = 2000 WHERE key = 'attendance_fine_late';
  UPDATE group_settings SET value = 4000 WHERE key = 'attendance_fine_absent';

  v_pool    := tests.pool();
  v_assets  := (SELECT total_assets_tzs FROM v_group_assets);
  v_earn    := (SELECT COALESCE(SUM(amount), 0) FROM earnings_ledger);
  v_capital := (SELECT member_capital_tzs FROM v_pool_reconciliation);
  v_events  := (SELECT count(*) FROM v_member_capital_events WHERE member_id = v_m);

  PERFORM tests.as_user(v_admin);
  v_sub := record_payment(v_m, 'fine_late', NULL, 2000, NULL);
  PERFORM tests.as_owner();

  -- The same reasoning as a monthly fee: the amount is the group's, not a judgement
  -- call, so there is nothing for a second pair of eyes to add.
  PERFORM tests.eq((SELECT status FROM payment_submissions WHERE id = v_sub), 'approved',
    'another member''s fine posts on one signature');

  -- ---------------------------------------------------- half one: the group has it
  PERFORM tests.eq(tests.pool(), v_pool + 2000, 'the fine is in the loan pool');
  PERFORM tests.eq((SELECT total_assets_tzs FROM v_group_assets), v_assets + 2000,
    'and in the group''s assets, so the 25% ceiling rises with it');
  PERFORM tests.eq((SELECT COALESCE(SUM(amount), 0) FROM earnings_ledger), v_earn + 2000,
    'it is booked as group income');
  PERFORM tests.eq(
    (SELECT COALESCE(SUM(amount), 0) FROM earnings_ledger
      WHERE submission_id = v_sub AND kind = 'penalty' AND source_type = 'fine_late'),
    2000, 'against the submission, under the penalty line of the income statement');

  -- ------------------------------------------------- half two: the member does not
  PERFORM tests.eq(member_savings(v_m), 100000, 'THE RULE: the member''s savings do not move');
  PERFORM tests.eq((SELECT member_capital_tzs FROM v_pool_reconciliation), v_capital,
    'nor does member capital across the group');
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM v_member_capital_events WHERE member_id = v_m), v_events,
    'nor does it appear in their capital history, which is what share-out weighting reads');
  PERFORM tests.eq(
    (SELECT COALESCE(SUM(delta), 0) FROM savings_adjustments WHERE target_member_id = v_m),
    0, 'and paying cash is not the register''s deduction: nothing comes out of savings either');

  PERFORM tests.assert_balanced('a fine paid in cash');

  -- The second fine type takes the same path.
  v_pool := tests.pool();
  PERFORM tests.as_user(v_a2);
  v_sub := record_payment(v_m, 'fine_absent', NULL, 4000, NULL);
  PERFORM tests.as_owner();

  PERFORM tests.eq(tests.pool(), v_pool + 4000, 'a fine for missing the meeting reaches the pool');
  PERFORM tests.eq(member_savings(v_m), 100000, 'and does not reach their savings');
  PERFORM tests.eq(
    (SELECT COALESCE(SUM(amount), 0) FROM earnings_ledger
      WHERE submission_id = v_sub AND source_type = 'fine_absent'),
    4000, 'each fine type stays identifiable in the ledger');
  PERFORM tests.assert_balanced('a fine for missing the meeting');
END;
$$;

-- ============================================================================
-- B. The amount is the group's. On one signature, a slipped zero must not post.
-- ============================================================================
DO $$
DECLARE
  v_admin uuid;
  v_m     uuid;
  v_sub   uuid;
  v_pool  numeric;
BEGIN
  v_admin := tests.make_admin('FineB Admin');
  v_m     := tests.make_member('FineB Member');

  UPDATE group_settings SET value = 2000 WHERE key = 'attendance_fine_late';
  UPDATE group_settings SET value = 4000 WHERE key = 'attendance_fine_absent';
  v_pool := tests.pool();

  PERFORM tests.as_user(v_admin);
  PERFORM tests.raises(
    format($q$ SELECT record_payment(%L, 'fine_late', NULL, 20000, NULL) $q$, v_m),
    'a fine above the group''s amount is refused');
  PERFORM tests.raises(
    format($q$ SELECT record_payment(%L, 'fine_late', NULL, 2001, NULL) $q$, v_m),
    'even by one shilling');
  -- Each type has its own ceiling: 4,000 is right for absent and wrong for late.
  PERFORM tests.raises(
    format($q$ SELECT record_payment(%L, 'fine_late', NULL, 4000, NULL) $q$, v_m),
    'a late fine cannot be charged at the absent rate');
  PERFORM tests.raises(
    format($q$ SELECT record_payment(%L, 'fine_absent', NULL, 0, NULL) $q$, v_m),
    'a fine of nothing is refused');
  PERFORM tests.as_owner();

  PERFORM tests.eq(tests.pool(), v_pool, 'nothing refused reached the pool');

  -- Part of a fine is still money that arrived. Enter what arrived.
  PERFORM tests.as_user(v_admin);
  v_sub := record_payment(v_m, 'fine_absent', NULL, 1500, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.eq(tests.pool(), v_pool + 1500, 'part of a fine is recorded at what arrived');

  -- The amount follows the group's vote.
  UPDATE group_settings SET value = 3000 WHERE key = 'attendance_fine_late';
  PERFORM tests.as_user(v_admin);
  v_sub := record_payment(v_m, 'fine_late', NULL, 3000, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM payment_submissions WHERE id = v_sub), 'approved',
    'the ceiling is whatever the group has voted, not a number in the code');

  -- A fine the group has switched off cannot be collected.
  UPDATE group_settings SET value = 0 WHERE key = 'attendance_fine_late';
  PERFORM tests.as_user(v_admin);
  PERFORM tests.raises(
    format($q$ SELECT record_payment(%L, 'fine_late', NULL, 1000, NULL) $q$, v_m),
    'no amount fits a fine set to zero');
  -- The rest of the type check still stands.
  PERFORM tests.raises(
    format($q$ SELECT record_payment(%L, 'fine_whatever', NULL, 1000, NULL) $q$, v_m),
    'an unknown payment type is still refused');
  PERFORM tests.as_owner();

  -- Only an admin records money.
  UPDATE group_settings SET value = 2000 WHERE key = 'attendance_fine_late';
  PERFORM tests.as_user(v_m);
  PERFORM tests.raises(
    format($q$ SELECT record_payment(%L, 'fine_late', NULL, 2000, NULL) $q$, v_m),
    'a member cannot record a fine');
  PERFORM tests.as_owner();

  PERFORM tests.assert_balanced('the fine amount guards');
END;
$$;

-- ============================================================================
-- C. An admin's own fine still takes a second signature; the overseer's does not.
-- ============================================================================
DO $$
DECLARE
  v_a1   uuid;
  v_a2   uuid;
  v_sub  uuid;
  v_pool numeric;
BEGIN
  v_a1 := tests.make_admin('FineC Admin One');
  v_a2 := tests.make_admin('FineC Admin Two');
  UPDATE group_settings SET value = 2000 WHERE key = 'attendance_fine_late';
  UPDATE group_settings SET value = 4000 WHERE key = 'attendance_fine_absent';
  PERFORM tests.give_savings(v_a1, 50000);
  v_pool := tests.pool();

  PERFORM tests.as_user(v_a1);
  v_sub := record_payment(v_a1, 'fine_late', NULL, 2000, NULL);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM payment_submissions WHERE id = v_sub), 'pending',
    'an admin''s own fine waits for a second signature');
  PERFORM tests.eq(tests.pool(), v_pool, 'and is not in the pool yet');
  PERFORM tests.eq(
    (SELECT COALESCE(SUM(amount), 0) FROM earnings_ledger WHERE submission_id = v_sub),
    0, 'nor in the group''s income');
  PERFORM tests.assert_balanced('a fine waiting for its signature');

  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT approve_submission(%L, 2000) $q$, v_sub),
    'they cannot sign their own fine');
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_a2);
  PERFORM approve_submission(v_sub, 2000);
  PERFORM tests.as_owner();

  PERFORM tests.eq(tests.pool(), v_pool + 2000, 'the second signature posts it');
  PERFORM tests.eq(member_savings(v_a1), 50000, 'an admin''s savings are safe from it too');
  PERFORM tests.assert_balanced('a second signature on a fine');
END;
$$;

DO $$
DECLARE
  v_o    uuid;
  v_sub  uuid;
  v_pool numeric;
BEGIN
  v_o := tests.make_overseer('FineC Overseer');
  UPDATE group_settings SET value = 2000 WHERE key = 'attendance_fine_late';
  v_pool := tests.pool();

  PERFORM tests.as_user(v_o);
  v_sub := record_payment(v_o, 'fine_late', NULL, 2000, NULL);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM payment_submissions WHERE id = v_sub), 'approved',
    'the overseer settles their own fine alone');
  PERFORM tests.eq(tests.pool(), v_pool + 2000, 'and it reaches the pool');
  PERFORM tests.eq(member_savings(v_o), 0, 'and not their savings');
  PERFORM tests.assert_balanced('the overseer''s own fine');
END;
$$;

-- ============================================================================
-- D. THE POINT OF IT ALL: fine money can actually go out as a loan.
-- ============================================================================
DO $$
DECLARE
  v_o      uuid;
  v_fined  uuid;
  v_lender uuid;
  v_last   uuid;
  v_loan   uuid;
  v_out    numeric;
BEGIN
  -- The overseer signs alone, so one approve_loan call either pays out or refuses.
  v_o      := tests.make_overseer('FineD Overseer');
  v_fined  := tests.make_member('FineD Fined Member');
  v_lender := tests.make_member('FineD Existing Borrower');
  v_last   := tests.make_member('FineD Last Borrower');
  UPDATE group_settings SET value = 4000 WHERE key = 'attendance_fine_absent';

  -- Enough saved that the contribution and 25% arms never bite; only cash can.
  PERFORM tests.give_savings(v_last, 1000000);

  -- Every shilling the pool holds is already out on loan. That also leaves the
  -- group's ASSETS high, so a refusal below can only be about cash.
  v_out := tests.pool();
  INSERT INTO loans (member_id, principal, outstanding_principal, status)
  VALUES (v_lender, v_out, v_out, 'active');
  PERFORM tests.eq(tests.pool(), 0, 'the pool is empty');
  PERFORM tests.assert_balanced('lending out the whole pool');

  INSERT INTO loans (member_id, principal, status)
  VALUES (v_last, 3000, 'pending') RETURNING id INTO v_loan;

  PERFORM tests.as_user(v_o);
  PERFORM tests.raises(format($q$ SELECT approve_loan(%L, 'test://d') $q$, v_loan),
    'with an empty pool the loan cannot be paid');
  PERFORM record_payment(v_fined, 'fine_absent', NULL, 4000, NULL);
  PERFORM tests.as_owner();

  PERFORM tests.eq(tests.pool(), 4000, 'the fine is all the cash there is');

  PERFORM tests.as_user(v_o); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan), 'active',
    'the fine paid for a loan to another member');
  PERFORM tests.eq(tests.pool(), 1000, 'and what is left stays lendable');
  PERFORM tests.assert_balanced('a loan paid out of a fine');
END;
$$;

-- ============================================================================
-- E. Undoing a mistake: the void returns everything to where it was.
-- ============================================================================
DO $$
DECLARE
  v_a1   uuid;
  v_a2   uuid;
  v_m    uuid;
  v_sub  uuid;
  v_void uuid;
  v_pool numeric;
  v_earn numeric;
  v_rej  uuid;
BEGIN
  v_a1 := tests.make_admin('FineE Admin One');
  v_a2 := tests.make_admin('FineE Admin Two');
  v_m  := tests.make_member('FineE Member');
  PERFORM tests.give_savings(v_m, 30000);
  UPDATE group_settings SET value = 4000 WHERE key = 'attendance_fine_absent';

  v_pool := tests.pool();
  v_earn := (SELECT COALESCE(SUM(amount), 0) FROM earnings_ledger);

  -- Fined the wrong member.
  PERFORM tests.as_user(v_a1);
  v_sub := record_payment(v_m, 'fine_absent', NULL, 4000, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.eq(tests.pool(), v_pool + 4000, 'the mistaken fine is in the pool');

  PERFORM tests.eq(payment_void_blocker(v_sub), NULL::text, 'a settled fine can be voided');

  PERFORM tests.as_user(v_a1);
  v_void := request_payment_void(v_sub, 'Wrong member, they were present');
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM approve_payment_void(v_void);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM payment_submissions WHERE id = v_sub), 'voided',
    'the fine is voided');
  PERFORM tests.eq(tests.pool(), v_pool, 'the money is out of the pool');
  PERFORM tests.eq((SELECT COALESCE(SUM(amount), 0) FROM earnings_ledger), v_earn,
    'and out of the group''s income');
  PERFORM tests.eq(member_savings(v_m), 30000, 'and savings were never involved');
  PERFORM tests.assert_balanced('voiding a fine');

  -- A pending fine that gets rejected never touched anything.
  PERFORM tests.as_user(v_a1);
  v_rej := record_payment(v_a1, 'fine_absent', NULL, 4000, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM reject_submission(v_rej, 'They had sent word');
  PERFORM tests.as_owner();
  PERFORM tests.eq(tests.pool(), v_pool, 'a rejected fine moves nothing');
  PERFORM tests.assert_balanced('rejecting a fine');
END;
$$;

-- ============================================================================
-- F. What the member is told, and what the reports call it.
-- ============================================================================
DO $$
DECLARE
  v_admin uuid;
  v_m     uuid;
  v_sub   uuid;
  v_body  text;
  v_before numeric;
BEGIN
  v_admin := tests.make_admin('FineF Admin');
  v_m     := tests.make_member('FineF Member');
  UPDATE group_settings SET value = 2000 WHERE key = 'attendance_fine_late';
  UPDATE group_settings SET value = 4000 WHERE key = 'attendance_fine_absent';
  UPDATE profiles SET preferred_language = 'en' WHERE id = v_m;

  -- Yesterday too: the statement dates rows by the database's UTC day, which is still
  -- yesterday for the first three hours of a day in Dar es Salaam.
  v_before := (SELECT penalty_tzs FROM group_income_statement(today_eat() - 1, today_eat()));

  PERFORM tests.as_user(v_admin);
  v_sub := record_payment(v_m, 'fine_late', NULL, 2000, NULL);
  PERFORM record_payment(v_m, 'fine_absent', NULL, 4000, NULL);
  PERFORM tests.as_owner();

  SELECT body INTO v_body FROM notifications
   WHERE recipient_id = v_m AND kind = 'submission_approved'
     AND data ->> 'submission_id' = v_sub::text;
  PERFORM tests.eq(v_body, 'Your late-arrival fine was approved.',
    'the member reads words, not a column value');
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notifications
      WHERE recipient_id = v_m AND body LIKE '%fine\_%'),
    0, 'no raw type name reaches a member');

  PERFORM tests.eq((SELECT penalty_tzs FROM group_income_statement(today_eat() - 1, today_eat())),
    v_before + 6000, 'fines count as income on the income statement');
  PERFORM tests.eq(
    (SELECT difference_tzs FROM group_balance_sheet()), 0,
    'and the balance sheet balances with them on it');
  PERFORM tests.eq((SELECT r.penalties_tzs FROM group_member_report() r
                     WHERE r.member_id = v_m), 6000,
    'and the member report shows who paid them');
  PERFORM tests.eq((SELECT r.capital_tzs FROM group_member_report() r
                     WHERE r.member_id = v_m), 0,
    'while still showing no capital for them');
END;
$$;
