-- 12_payment_void.test.sql — reversing an admin's typo (037).
--
-- The assertion that matters in every block is tests.assert_balanced(). A void
-- touches the pool, member capital and retained earnings at once, and getting one
-- of the three wrong produces a plausible-looking balance that is quietly off — the
-- same class of bug the attendance fines in 030 had. The reconciliation identity is
-- the only thing that catches it.
--
-- The second theme is what a void REFUSES. A reversal that unwinds one payment out
-- from under a schedule that has since moved on is worse than no reversal at all,
-- so the refusals are tested as carefully as the successes.

-- ============================================================================
-- A. A mistyped savings deposit. The simplest case: one flag.
-- ============================================================================
DO $$
DECLARE
  v_a1     uuid;
  v_a2     uuid;
  v_m      uuid;
  v_sub    uuid;
  v_void   uuid;
  v_before numeric;
BEGIN
  v_a1 := tests.make_admin('VoidA Admin One');
  v_a2 := tests.make_admin('VoidA Admin Two');
  v_m  := tests.make_member('VoidA Member');

  v_before := tests.pool();

  -- 50,000 keyed when the member paid 5,000.
  PERFORM tests.as_user(v_a1);
  v_sub := record_payment(v_m, 'savings_deposit', NULL, 50000, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM approve_submission(v_sub, 50000);
  PERFORM tests.as_owner();

  PERFORM tests.eq(tests.pool(), v_before + 50000, 'the wrong figure is in the pool');
  PERFORM tests.assert_balanced('a mistyped deposit');

  -- One signature is not a correction.
  PERFORM tests.as_user(v_a1);
  v_void := request_payment_void(v_sub, 'Keyed 50,000, member paid 5,000');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM payment_submissions WHERE id = v_sub), 'approved',
    'one signature does not void anything');
  PERFORM tests.eq(tests.pool(), v_before + 50000, 'and the money has not moved back');

  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT approve_payment_void(%L) $q$, v_void),
    'the requesting admin cannot also be the second signature');
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_a2);
  PERFORM approve_payment_void(v_void);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM payment_submissions WHERE id = v_sub), 'voided',
    'two signatures void it');
  PERFORM tests.eq(tests.pool(), v_before, 'the pool is back where it started');
  PERFORM tests.assert_balanced('voiding a deposit');

  -- The row is still there. A void is a correction, not an erasure.
  PERFORM tests.eq(
    (SELECT count(*) FROM payment_submissions WHERE id = v_sub)::numeric, 1,
    'the original entry is retained');

  -- And it cannot be voided twice.
  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT request_payment_void(%L, 'again') $q$, v_sub),
    'a voided entry cannot be voided again');
  PERFORM tests.as_owner();

  RAISE NOTICE '12A ok';
END;
$$;

-- ============================================================================
-- B. A fee, with penalty. The penalty has to come back out of earnings or the
--    books stop balancing.
-- ============================================================================
DO $$
DECLARE
  v_a1     uuid;
  v_a2     uuid;
  v_m      uuid;
  v_fee    uuid;
  v_sub    uuid;
  v_void   uuid;
  v_period date := (date_trunc('month', today_eat()) - interval '3 months')::date;
  v_before numeric;
  v_earn   numeric;
BEGIN
  v_a1 := tests.make_admin('VoidB Admin One');
  v_a2 := tests.make_admin('VoidB Admin Two');
  v_m  := tests.make_member('VoidB Member');

  -- An old period, so real penalty has accrued.
  v_fee := tests.give_fee(v_m, v_period);

  v_before := tests.pool();
  SELECT COALESCE(SUM(amount), 0) INTO v_earn FROM earnings_ledger;

  PERFORM tests.as_user(v_a1);
  PERFORM record_fee_payments(jsonb_build_array(
    jsonb_build_object('fee_id', v_fee, 'amount', 10000)));
  PERFORM tests.as_owner();

  SELECT id INTO v_sub FROM payment_submissions WHERE related_id = v_fee;

  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee), 'partial',
    'paying only the base leaves the penalty owing');
  PERFORM tests.eq((SELECT applied_base FROM payment_submissions WHERE id = v_sub),
    10000 - (SELECT applied_penalty FROM payment_submissions WHERE id = v_sub),
    'the allocation is recorded on the row');
  PERFORM tests.assert_balanced('a late fee payment');

  PERFORM tests.as_user(v_a1);
  v_void := request_payment_void(v_sub, 'Wrong member');
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM approve_payment_void(v_void);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT amount_paid FROM monthly_fees WHERE id = v_fee), 0,
    'the fee is unpaid again');
  PERFORM tests.eq((SELECT penalty_collected FROM monthly_fees WHERE id = v_fee), 0,
    'and the banked penalty is reversed');
  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee), 'pending',
    'the fee is back to pending, not stuck on partial');
  PERFORM tests.eq((SELECT paid_at IS NULL FROM monthly_fees WHERE id = v_fee)::text,
    'true', 'and carries no paid date');
  PERFORM tests.eq((SELECT COALESCE(SUM(amount), 0) FROM earnings_ledger), v_earn,
    'retained earnings are back where they were');
  PERFORM tests.eq(tests.pool(), v_before, 'the pool is back where it started');
  PERFORM tests.assert_balanced('voiding a fee payment');

  RAISE NOTICE '12B ok';
END;
$$;

-- ============================================================================
-- C. A loan repayment. Principal has to go back out on loan, interest has to
--    come back out of earnings, and the schedule has to be re-priced.
-- ============================================================================
DO $$
DECLARE
  v_a1     uuid;
  v_a2     uuid;
  v_m      uuid;
  v_loan   uuid;
  v_inst   uuid;
  v_sub    uuid;
  v_void   uuid;
  v_before numeric;
  v_out    numeric;
BEGIN
  v_a1 := tests.make_admin('VoidC Admin One');
  v_a2 := tests.make_admin('VoidC Admin Two');
  v_m  := tests.make_member('VoidC Member');

  PERFORM tests.give_savings(v_m, 300000);

  PERFORM tests.as_user(v_a1);
  v_loan := file_loan(v_m, 60000);
  PERFORM approve_loan(v_loan, 'test://d');
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM approve_loan(v_loan, 'test://d');
  PERFORM tests.as_owner();

  SELECT id INTO v_inst FROM loan_installments
   WHERE loan_id = v_loan AND installment_number = 1;

  v_before := tests.pool();
  PERFORM tests.assert_balanced('a fresh loan');

  -- 23,000: 3,000 interest and 20,000 off the principal early.
  PERFORM tests.as_user(v_a1);
  v_sub := record_payment(v_m, 'loan_installment', v_inst, 23000, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM approve_submission(v_sub, 23000);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_loan), 40000,
    'principal came down');
  PERFORM tests.eq((SELECT applied_principal FROM payment_submissions WHERE id = v_sub),
    20000, 'the principal share is recorded');
  PERFORM tests.eq((SELECT applied_interest FROM payment_submissions WHERE id = v_sub),
    3000, 'the interest share is recorded');
  PERFORM tests.eq(tests.pool(), v_before + 23000, 'the pool took all of it');
  PERFORM tests.assert_balanced('an early principal repayment');

  PERFORM tests.as_user(v_a1);
  v_void := request_payment_void(v_sub, 'Recorded against the wrong loan');
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM approve_payment_void(v_void);
  PERFORM tests.as_owner();

  SELECT outstanding_principal INTO v_out FROM loans WHERE id = v_loan;
  PERFORM tests.eq(v_out, 60000, 'the principal is out on loan again');
  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_inst), 0,
    'the interest payment is reversed');
  PERFORM tests.eq((SELECT principal_paid FROM loan_installments WHERE id = v_inst), 0,
    'the principal payment is reversed');
  PERFORM tests.eq((SELECT status FROM loan_installments WHERE id = v_inst), 'pending',
    'the installment is outstanding again, not stuck on partial');
  PERFORM tests.eq(tests.pool(), v_before, 'the pool is back where it started');
  PERFORM tests.assert_balanced('voiding a repayment');

  -- Re-priced off the restored balance: 5% of 60,000 again.
  PERFORM tests.eq((SELECT interest_due FROM loan_installments WHERE id = v_inst), 3000,
    'the schedule is re-priced off the restored principal');

  RAISE NOTICE '12C ok';
END;
$$;

-- ============================================================================
-- D. What it refuses. Each of these would silently corrupt a schedule if the
--    reversal went ahead.
-- ============================================================================
DO $$
DECLARE
  v_a1   uuid;
  v_a2   uuid;
  v_m    uuid;
  v_loan uuid;
  v_i1   uuid;
  v_i2   uuid;
  v_sub1 uuid;
  v_sub2 uuid;
  v_old  uuid;
  v_fee  uuid;
BEGIN
  v_a1 := tests.make_admin('VoidD Admin One');
  v_a2 := tests.make_admin('VoidD Admin Two');
  v_m  := tests.make_member('VoidD Member');

  PERFORM tests.give_savings(v_m, 300000);

  PERFORM tests.as_user(v_a1);
  v_loan := file_loan(v_m, 60000);
  PERFORM approve_loan(v_loan, 'test://d');
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM approve_loan(v_loan, 'test://d');
  PERFORM tests.as_owner();

  SELECT id INTO v_i1 FROM loan_installments WHERE loan_id = v_loan AND installment_number = 1;
  SELECT id INTO v_i2 FROM loan_installments WHERE loan_id = v_loan AND installment_number = 2;

  -- Two repayments, the second landing after the first.
  PERFORM tests.as_user(v_a1);
  v_sub1 := record_payment(v_m, 'loan_installment', v_i1, 3000, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM approve_submission(v_sub1, 3000);
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_a1);
  v_sub2 := record_payment(v_m, 'loan_installment', v_i2, 3000, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM approve_submission(v_sub2, 3000);
  PERFORM tests.as_owner();

  -- The earlier one is now buried: re-pricing has run over the top of it.
  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT request_payment_void(%L, 'x') $q$, v_sub1),
    'a repayment cannot be voided once a later one has landed on the loan');
  PERFORM tests.as_owner();

  -- The most recent one still can.
  PERFORM tests.eq(COALESCE(payment_void_blocker(v_sub2), 'ok'), 'ok',
    'the latest repayment is still reversible');

  -- A reason is not optional: a void with no explanation is unauditable.
  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT request_payment_void(%L, '   ') $q$, v_sub2),
    'a void needs a reason');
  PERFORM tests.as_owner();

  -- Rows settled before 037 carry no allocation, so there is nothing exact to
  -- reverse. This is the shape of every historical row in the live database.
  v_fee := tests.give_fee(v_m, (date_trunc('month', today_eat()) - interval '2 months')::date);
  v_old := tests.submit_payment(v_m, 'monthly_fee', v_fee, 10000);
  UPDATE payment_submissions
     SET status = 'approved', reviewed_at = now() - interval '30 days'
   WHERE id = v_old;

  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT request_payment_void(%L, 'x') $q$, v_old),
    'a pre-037 payment cannot be voided');
  PERFORM tests.as_owner();

  -- And a member is nowhere near any of this.
  PERFORM tests.as_user(v_m);
  PERFORM tests.raises(format($q$ SELECT request_payment_void(%L, 'x') $q$, v_sub2),
    'a member cannot request a void');
  PERFORM tests.raises($q$ SELECT execute_payment_void(gen_random_uuid()) $q$,
    'a member cannot execute a void directly');
  PERFORM tests.as_owner();

  RAISE NOTICE '12D ok';
END;
$$;
