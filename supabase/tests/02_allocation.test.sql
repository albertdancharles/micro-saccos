-- 02_allocation.test.sql — the payment waterfall in approve_submission (021).
--
-- Mirrors src/lib/allocation.test.js case for case. That JS suite passes today, but
-- it tests the PREVIEW; this one tests the code that actually moves money.
--
--   monthly fee        penalty → base
--   loan installment   penalty → interest → contracted principal → extra principal
--
-- Penalty first is the rule that matters most: paying principal while a penalty
-- compounds costs the member money every month.

DO $$
DECLARE
  v_admin   uuid;
  v_member  uuid;
  v_funder  uuid;
  v_fee     uuid;
  v_sub     uuid;
  v_loan    uuid;
  v_i1      uuid;
  v_i2      uuid;
  v_i3      uuid;
  v_penalty numeric;
  v_r       record;
BEGIN
  v_admin  := tests.make_admin('Alloc Admin');
  v_member := tests.make_member('Alloc Member');
  v_funder := tests.make_member('Alloc Funder');

  -- ======================================================== monthly fee
  -- A 10,000 fee, three months overdue, so a penalty has genuinely accrued.
  v_fee := tests.give_fee(v_member, (date_trunc('month', today_eat()) - INTERVAL '3 months')::date);
  SELECT penalty_due INTO v_penalty FROM v_fee_status_money WHERE id = v_fee;
  IF v_penalty <= 0 THEN RAISE EXCEPTION 'fixture: the fee should be accruing a penalty'; END IF;

  -- Pay the penalty plus 500 of the base.
  v_sub := tests.submit_payment(v_member, 'monthly_fee', v_fee, v_penalty + 500);
  PERFORM tests.as_user(v_admin);
  PERFORM approve_submission(v_sub, v_penalty + 500);
  PERFORM tests.as_owner();

  SELECT * INTO v_r FROM monthly_fees WHERE id = v_fee;
  PERFORM tests.eq(v_r.penalty_collected, v_penalty, 'penalty is settled first');
  PERFORM tests.eq(v_r.amount_paid, 500, 'the remainder goes to the base');
  PERFORM tests.eq(v_r.status, 'partial', 'a part-settled fee is not marked paid');

  -- The penalty now accrues on the 9,500 still owed, not the original 10,000.
  SELECT * INTO v_r FROM v_fee_status_money WHERE id = v_fee;
  PERFORM tests.eq(v_r.remaining, 9500, 'remaining tracks what is still owed');
  PERFORM tests.eq(v_r.penalty_due, round(v_r.penalty_rate * 9500 * v_r.penalty_months),
    'penalty accrues on the remaining balance, not the original total');

  -- Clear it.
  SELECT total_with_penalty INTO v_penalty FROM v_fee_status_money WHERE id = v_fee;
  v_sub := tests.submit_payment(v_member, 'monthly_fee', v_fee, v_penalty);
  PERFORM tests.as_user(v_admin);
  PERFORM approve_submission(v_sub, v_penalty);
  PERFORM tests.as_owner();

  SELECT * INTO v_r FROM monthly_fees WHERE id = v_fee;
  PERFORM tests.eq(v_r.amount_paid, 10000, 'the fee is fully settled');
  PERFORM tests.eq(v_r.status, 'paid', 'zero remaining flips it to paid');

  -- ======================================================== loan installments
  -- Pool of 1,000,000 so the 25% cap allows a 100,000 loan; the borrower's own
  -- 100,000 clears the 5x contribution cap.
  PERFORM tests.give_savings(v_funder, 900000);
  PERFORM tests.give_savings(v_member, 100000);

  INSERT INTO loans (member_id, principal, status)
  VALUES (v_member, 100000, 'pending') RETURNING id INTO v_loan;

  PERFORM tests.as_user(v_admin);
  PERFORM approve_loan(v_loan, 'test://disbursement');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan), 'active', 'loan activated');
  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_loan), 100000,
    'outstanding starts at the full principal');
  PERFORM tests.eq((SELECT count(*)::numeric FROM loan_installments WHERE loan_id = v_loan), 3,
    'a 3-month term produces 3 installments');

  SELECT id INTO v_i1 FROM loan_installments WHERE loan_id = v_loan AND installment_number = 1;
  SELECT id INTO v_i2 FROM loan_installments WHERE loan_id = v_loan AND installment_number = 2;
  SELECT id INTO v_i3 FROM loan_installments WHERE loan_id = v_loan AND installment_number = 3;

  PERFORM tests.eq((SELECT interest_due FROM loan_installments WHERE id = v_i1), 5000,
    'interest is 5% of principal');
  PERFORM tests.eq((SELECT principal_due FROM loan_installments WHERE id = v_i3), 100000,
    'only the final installment carries principal');

  -- ------------------------------------------- underpay: interest, partially
  v_sub := tests.submit_payment(v_member, 'loan_installment', v_i1, 3000);
  PERFORM tests.as_user(v_admin);
  PERFORM approve_submission(v_sub, 3000);
  PERFORM tests.as_owner();

  SELECT * INTO v_r FROM loan_installments WHERE id = v_i1;
  PERFORM tests.eq(v_r.interest_paid, 3000, 'an underpayment goes to interest');
  PERFORM tests.eq(v_r.principal_paid, 0, 'principal is untouched while interest is owed');
  PERFORM tests.eq(v_r.status, 'partial', 'the installment is part paid');
  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_loan), 100000,
    'an interest underpayment does not reduce the principal');

  -- …then finish it.
  v_sub := tests.submit_payment(v_member, 'loan_installment', v_i1, 2000);
  PERFORM tests.as_user(v_admin);
  PERFORM approve_submission(v_sub, 2000);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM loan_installments WHERE id = v_i1), 'paid',
    'the installment closes once interest is covered');

  -- ------------------------------------------- overpay: early principal
  -- 5,000 interest + 50,000 straight off the principal.
  v_sub := tests.submit_payment(v_member, 'loan_installment', v_i2, 55000);
  PERFORM tests.as_user(v_admin);
  PERFORM approve_submission(v_sub, 55000);
  PERFORM tests.as_owner();

  SELECT * INTO v_r FROM loan_installments WHERE id = v_i2;
  PERFORM tests.eq(v_r.interest_paid, 5000, 'interest first');
  PERFORM tests.eq(v_r.principal_paid, 50000, 'the surplus retires principal early');
  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_loan), 50000,
    'outstanding falls by the early repayment');

  -- The final installment is re-priced against the new balance.
  SELECT * INTO v_r FROM loan_installments WHERE id = v_i3;
  PERFORM tests.eq(v_r.interest_due, 2500, 'remaining interest is re-priced on the new balance');
  PERFORM tests.eq(v_r.principal_due, 50000, 'the final installment clears what is left');

  -- ------------------------------------------- the ceiling
  PERFORM tests.as_user(v_admin);
  PERFORM tests.raises(
    format($q$ SELECT approve_submission(%L, 999999) $q$,
           tests.submit_payment(v_member, 'loan_installment', v_i3, 999999)),
    'a payment beyond everything outstanding is refused, not booked as a penalty');
  PERFORM tests.as_owner();

  -- ------------------------------------------- settle and close
  DELETE FROM payment_submissions WHERE related_id = v_i3 AND status = 'pending';
  v_sub := tests.submit_payment(v_member, 'loan_installment', v_i3, 52500);
  PERFORM tests.as_user(v_admin);
  PERFORM approve_submission(v_sub, 52500);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_loan), 0,
    'the loan is fully repaid');
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan), 'closed', 'the loan closes');

  -- ------------------------------------------- earnings were recorded
  -- Interest is the group's profit; principal coming back is not.
  PERFORM tests.eq(
    (SELECT COALESCE(SUM(amount), 0) FROM earnings_ledger
      WHERE kind = 'interest' AND source_type = 'loan_installment'),
    12500, 'interest collected is booked as earnings (5000 + 5000 + 2500)');
END;
$$;
