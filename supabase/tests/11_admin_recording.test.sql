-- 11_admin_recording.test.sql — the intake after the admin mandate (036).
--
-- This is the money path now: every shilling that enters the system comes through
-- record_fee_payments or record_payment. Two things need pinning.
--
-- FIRST, the signature rules, which are not uniform and are easy to get subtly
-- wrong: one admin for another member's fee, two for anything variable, two ALWAYS
-- for an admin's own money even in a group small enough that everything else
-- degrades to a single signature.
--
-- SECOND, that splitting the waterfall out of approve_submission into
-- settle_submission did not change the arithmetic. The parity assertions below are
-- the reason that refactor is safe: the same payment through the new path must land
-- the same penalty, interest and principal as the old one, and leave the pool
-- balanced.

-- ============================================================================
-- A. One admin: fees post immediately, and the arithmetic is unchanged.
-- ============================================================================
DO $$
DECLARE
  v_admin  uuid;
  v_m1     uuid;
  v_m2     uuid;
  v_fee1   uuid;
  v_fee2   uuid;
  v_period date := date_trunc('month', today_eat())::date;
  v_before numeric;
  v_n      int;
BEGIN
  v_admin := tests.make_admin('Rec Admin');
  v_m1    := tests.make_member('Rec One');
  v_m2    := tests.make_member('Rec Two');

  v_fee1 := tests.give_fee(v_m1, v_period);
  v_fee2 := tests.give_fee(v_m2, v_period);

  v_before := tests.pool();

  PERFORM tests.as_user(v_admin);
  v_n := record_fee_payments(jsonb_build_array(
    jsonb_build_object('fee_id', v_fee1, 'amount', 10000),
    jsonb_build_object('fee_id', v_fee2, 'amount', 10000)
  ));
  PERFORM tests.as_owner();

  PERFORM tests.eq(v_n, 2, 'the batch reports what it posted');
  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee1), 'paid',
    'a batched fee settles on one admin signature');
  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee2), 'paid',
    'every entry in the batch settles');
  PERFORM tests.eq(tests.pool(), v_before + 20000, 'the pool has both payments');
  PERFORM tests.assert_balanced('a batch of fees');

  -- The member is derived from the fee, never passed in, so a payment cannot be
  -- credited to the wrong person by a mistyped id.
  PERFORM tests.eq(
    (SELECT member_id::text FROM payment_submissions WHERE related_id = v_fee1),
    v_m1::text, 'the payment is credited to the fee''s owner');
  PERFORM tests.eq(
    (SELECT recorded_by::text FROM payment_submissions WHERE related_id = v_fee1),
    v_admin::text, 'the recording admin is on the row');

  -- All-or-nothing: a bad entry must not leave half a sheet posted.
  PERFORM tests.as_user(v_admin);
  PERFORM tests.raises(format($q$
    SELECT record_fee_payments(jsonb_build_array(
      jsonb_build_object('fee_id', %L, 'amount', 10000),
      jsonb_build_object('fee_id', %L, 'amount', 0)
    )) $q$, tests.give_fee(v_m1, (v_period - interval '1 month')::date), v_fee2),
    'a zero amount rejects the whole batch');
  PERFORM tests.as_owner();

  RAISE NOTICE '11A ok';
END;
$$;

-- ============================================================================
-- B. Members cannot reach any of it.
-- ============================================================================
DO $$
DECLARE
  v_admin uuid;
  v_m     uuid;
  v_fee   uuid;
BEGIN
  v_admin := tests.make_admin('RecB Admin');
  v_m     := tests.make_member('RecB Member');
  v_fee   := tests.give_fee(v_m, date_trunc('month', today_eat())::date);

  PERFORM tests.as_user(v_m);
  PERFORM tests.raises(format($q$
    SELECT record_fee_payments(jsonb_build_array(
      jsonb_build_object('fee_id', %L, 'amount', 10000))) $q$, v_fee),
    'a member cannot post their own fee as paid');
  PERFORM tests.raises(format($q$
    SELECT record_payment(%L, 'savings_deposit', NULL, 50000, NULL) $q$, v_m),
    'a member cannot record a savings deposit');
  PERFORM tests.raises(format($q$ SELECT file_loan(%L, 10000) $q$, v_m),
    'a member cannot file a loan');
  PERFORM tests.raises(format($q$
    SELECT admin_request_withdrawal(%L, 1, 'x') $q$, v_m),
    'a member cannot raise a withdrawal');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee), 'pending',
    'nothing moved');

  RAISE NOTICE '11B ok';
END;
$$;

-- ============================================================================
-- C. Two admins: the variable amounts need two signatures.
-- ============================================================================
DO $$
DECLARE
  v_a1  uuid;
  v_a2  uuid;
  v_m   uuid;
  v_sub uuid;
BEGIN
  v_a1 := tests.make_admin('RecC Admin One');
  v_a2 := tests.make_admin('RecC Admin Two');
  v_m  := tests.make_member('RecC Member');

  PERFORM tests.eq(required_approvals(), 2, 'two admins means two signatures');

  PERFORM tests.as_user(v_a1);
  v_sub := record_payment(v_m, 'savings_deposit', NULL, 50000, NULL);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM payment_submissions WHERE id = v_sub), 'pending',
    'a savings deposit does not post on one signature');
  PERFORM tests.eq(submission_threshold(v_sub), 2,
    'a variable amount needs two');

  -- The recorder already signed by recording; they cannot sign again.
  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT approve_submission(%L, 50000) $q$, v_sub),
    'the recording admin cannot supply the second signature');
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_a2);
  PERFORM approve_submission(v_sub, 50000);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM payment_submissions WHERE id = v_sub), 'approved',
    'the second admin settles it');
  PERFORM tests.assert_balanced('a two-signature savings deposit');

  -- But a fee for someone else still goes on one, in the same two-admin group.
  PERFORM tests.as_user(v_a1);
  PERFORM record_fee_payments(jsonb_build_array(jsonb_build_object(
    'fee_id', tests.give_fee(v_m, date_trunc('month', today_eat())::date),
    'amount', 10000)));
  PERFORM tests.as_owner();
  PERFORM tests.assert_balanced('a one-signature fee in a two-admin group');

  RAISE NOTICE '11C ok';
END;
$$;

-- ============================================================================
-- D. An admin's own money. Two signatures, always — and the deadlock is
--    reported up front rather than leaving a row that can never settle.
-- ============================================================================
DO $$
DECLARE
  v_a1  uuid;
  v_a2  uuid;
  v_fee uuid;
  v_sub uuid;
BEGIN
  -- The whole file runs in one transaction, so the admins created by the blocks
  -- above are still active here. Park them: this block is specifically about the
  -- one-admin group, where required_approvals() degrades to a single signature and
  -- self-recording would otherwise slip through unchecked.
  UPDATE profiles SET is_active = false WHERE role = 'admin';

  v_a1  := tests.make_admin('RecD Admin One');
  v_fee := tests.give_fee(v_a1, date_trunc('month', today_eat())::date);

  PERFORM tests.eq(required_approvals(), 1, 'a single admin normally signs alone');

  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$
    SELECT record_payment(%L, 'monthly_fee', %L, 10000, NULL) $q$, v_a1, v_fee),
    'a lone admin cannot record their own payment');
  PERFORM tests.raises(format($q$
    SELECT record_fee_payments(jsonb_build_array(
      jsonb_build_object('fee_id', %L, 'amount', 10000))) $q$, v_fee),
    'an admin cannot slip their own fee through the batch');
  PERFORM tests.as_owner();

  -- Promote a second admin and it becomes possible, but never on one signature.
  v_a2 := tests.make_admin('RecD Admin Two');

  PERFORM tests.as_user(v_a1);
  v_sub := record_payment(v_a1, 'monthly_fee', v_fee, 10000, NULL);
  PERFORM tests.as_owner();

  PERFORM tests.eq(submission_threshold(v_sub), 2,
    'an admin''s own money always needs two');
  PERFORM tests.eq((SELECT status FROM payment_submissions WHERE id = v_sub), 'pending',
    'the recorder''s own signature does not settle it');
  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee), 'pending',
    'and no money has moved');

  PERFORM tests.as_user(v_a2);
  PERFORM approve_submission(v_sub, 10000);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee), 'paid',
    'the other admin settles it');
  PERFORM tests.assert_balanced('an admin paying their own fee');

  -- Put the parked admins back so the blocks below see a normal group.
  UPDATE profiles SET is_active = true WHERE role = 'admin';

  RAISE NOTICE '11D ok';
END;
$$;

-- ============================================================================
-- E. Loans: filed by an admin, one at a time, and an admin may now borrow.
-- ============================================================================
DO $$
DECLARE
  v_a1   uuid;
  v_a2   uuid;
  v_m    uuid;
  v_loan uuid;
  v_own  uuid;
BEGIN
  v_a1 := tests.make_admin('RecE Admin One');
  v_a2 := tests.make_admin('RecE Admin Two');
  v_m  := tests.make_member('RecE Member');

  PERFORM tests.give_savings(v_m,  200000);
  PERFORM tests.give_savings(v_a1, 200000);
  PERFORM tests.give_savings(v_a2, 200000);

  PERFORM tests.as_user(v_a1);
  v_loan := file_loan(v_m, 50000);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan), 'pending',
    'filing a loan does not disburse it');

  -- The one-open-loan rule (Decision #4) is enforced in SQL for the first time;
  -- it used to live only in the client, which made it a disabled button, not a rule.
  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT file_loan(%L, 10000) $q$, v_m),
    'a member cannot have two loans in progress');
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_a1);
  PERFORM approve_loan(v_loan, 'test://d');
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan), 'pending',
    'one signature does not disburse');

  PERFORM tests.as_user(v_a2);
  PERFORM approve_loan(v_loan, 'test://d');
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan), 'active',
    'two signatures disburse');
  PERFORM tests.assert_balanced('an admin-filed loan');

  -- An admin may borrow (035 dropped the self-approval block), but cannot be
  -- both signatures on their own loan.
  PERFORM tests.as_user(v_a1);
  v_own := file_loan(v_a1, 20000);
  PERFORM approve_loan(v_own, 'test://d');
  PERFORM tests.raises(format($q$ SELECT approve_loan(%L, 'test://d') $q$, v_own),
    'an admin cannot sign their own loan twice');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_own), 'pending',
    'the borrowing admin''s own signature is not enough');

  PERFORM tests.as_user(v_a2);
  PERFORM approve_loan(v_own, 'test://d');
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_own), 'active',
    'a second admin can approve an admin''s loan');
  PERFORM tests.assert_balanced('an admin borrowing');

  RAISE NOTICE '11E ok';
END;
$$;

-- ============================================================================
-- F. Waterfall parity — the refactor did not move any money.
--
--    A repayment recorded through the new path must allocate exactly as it did
--    through approve_submission: penalty first, then interest, then principal.
--    The figures below are the same shape 02_allocation asserts for the old path.
-- ============================================================================
DO $$
DECLARE
  v_a1     uuid;
  v_a2     uuid;
  v_m      uuid;
  v_loan   uuid;
  v_inst   uuid;
  v_sub    uuid;
  v_before numeric;
BEGIN
  v_a1 := tests.make_admin('RecF Admin One');
  v_a2 := tests.make_admin('RecF Admin Two');
  v_m  := tests.make_member('RecF Member');

  PERFORM tests.give_savings(v_m, 200000);

  PERFORM tests.as_user(v_a1);
  v_loan := file_loan(v_m, 60000);
  PERFORM approve_loan(v_loan, 'test://d');
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM approve_loan(v_loan, 'test://d');
  PERFORM tests.as_owner();

  SELECT id INTO v_inst FROM loan_installments
   WHERE loan_id = v_loan AND installment_number = 1;

  -- 5% of 60,000 = 3,000 interest on installment 1, no principal due yet.
  PERFORM tests.eq((SELECT interest_due FROM loan_installments WHERE id = v_inst),
    3000, 'interest is 5% of principal');

  v_before := tests.pool();

  PERFORM tests.as_user(v_a1);
  v_sub := record_payment(v_m, 'loan_installment', v_inst, 3000, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM approve_submission(v_sub, 3000);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_inst),
    3000, 'the payment lands on interest');
  PERFORM tests.eq((SELECT principal_paid FROM loan_installments WHERE id = v_inst),
    0, 'and none of it on principal');
  PERFORM tests.eq(
    (SELECT COALESCE(SUM(amount), 0) FROM earnings_ledger
      WHERE submission_id = v_sub AND kind = 'interest'),
    3000, 'interest is booked as group earnings');
  PERFORM tests.eq(tests.pool(), v_before + 3000, 'the pool gained the interest');
  PERFORM tests.assert_balanced('an admin-recorded repayment');

  RAISE NOTICE '11F ok';
END;
$$;
