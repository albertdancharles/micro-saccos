-- 03_pool.test.sql — v_group_pool through every path money can take.
--
-- The pool is a 9-term expression over 7 tables that was rewritten three times in
-- one session (021 cash correction, 022 write-offs + recoveries, 024 distributions).
-- Nothing verified it. Every case below asserts the DELTA rather than an absolute,
-- so the file stays readable and each step is independently meaningful.
--
-- The two cases that would already have caught bugs:
--   * early principal repayment — the old view summed total_due, so principal paid
--     ahead of schedule never reached the pool at all
--   * recovery from savings — moves NO cash, so the pool must not budge, even
--     though a negative savings adjustment is written

DO $$
DECLARE
  v_admin  uuid;
  v_a      uuid;
  v_b      uuid;
  v_before numeric;
  v_fee    uuid;
  v_sub    uuid;
  v_loan   uuid;
  v_inst   uuid;
  v_act    uuid;
  v_wd     uuid;
  v_pen    numeric;
BEGIN
  v_admin := tests.make_admin('Pool Admin');
  v_a     := tests.make_member('Pool Alice');
  v_b     := tests.make_member('Pool Bob');

  PERFORM tests.eq(tests.pool(), 0, 'a fresh group holds nothing');

  -- =============================================== 1. savings deposit
  PERFORM tests.give_savings(v_a, 500000);
  PERFORM tests.give_savings(v_b, 500000);
  PERFORM tests.eq(tests.pool(), 1000000, 'approved deposits are the pool');
  PERFORM tests.assert_balanced('deposits');

  -- =============================================== 2. part-paid fee
  -- Cash in is what was actually banked, base AND penalty — not the contracted fee.
  v_fee := tests.give_fee(v_a, (date_trunc('month', today_eat()) - INTERVAL '2 months')::date);
  SELECT penalty_due INTO v_pen FROM v_fee_status_money WHERE id = v_fee;

  v_before := tests.pool();
  v_sub := tests.submit_payment(v_a, 'monthly_fee', v_fee, v_pen + 4000);
  PERFORM tests.as_user(v_admin);
  PERFORM approve_submission(v_sub, v_pen + 4000);
  PERFORM tests.as_owner();
  PERFORM tests.eq(tests.pool() - v_before, v_pen + 4000,
    'a part-paid fee credits exactly the cash received');
  PERFORM tests.assert_balanced('a part-paid fee');

  -- =============================================== 3. loan disbursed
  v_before := tests.pool();
  INSERT INTO loans (member_id, principal, status)
  VALUES (v_a, 100000, 'pending') RETURNING id INTO v_loan;
  PERFORM tests.as_user(v_admin);
  PERFORM approve_loan(v_loan, 'test://disbursement');
  PERFORM tests.as_owner();
  PERFORM tests.eq(tests.pool() - v_before, -100000, 'disbursing a loan takes cash out');
  PERFORM tests.assert_balanced('disbursing a loan');

  -- Total assets are unchanged: cash became a receivable, nothing was lost.
  PERFORM tests.eq(
    (SELECT total_assets_tzs FROM v_group_assets), v_before,
    'a disbursement moves value, it does not destroy it');

  -- =============================================== 4. early principal repayment
  -- THE REGRESSION CASE. 5,000 interest + 40,000 straight off the principal: all
  -- 45,000 is cash in the group's hands and must all reach the pool.
  SELECT id INTO v_inst FROM loan_installments WHERE loan_id = v_loan AND installment_number = 1;
  v_before := tests.pool();
  v_sub := tests.submit_payment(v_a, 'loan_installment', v_inst, 45000);
  PERFORM tests.as_user(v_admin);
  PERFORM approve_submission(v_sub, 45000);
  PERFORM tests.as_owner();
  PERFORM tests.eq(tests.pool() - v_before, 45000,
    'principal repaid early reaches the pool (the bug the old SUM(total_due) hid)');
  PERFORM tests.assert_balanced('early principal repayment');
  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_loan), 60000,
    'outstanding falls by the principal portion only');

  -- =============================================== 5. recover from savings
  -- No cash moves: the member's claim shrinks and the receivable shrinks with it.
  v_before := tests.pool();
  PERFORM tests.as_user(v_admin);
  v_act := request_loan_action(v_loan, 'recover_from_savings', 'test recovery', 20000, NULL);
  PERFORM tests.as_owner();

  PERFORM tests.eq(tests.pool(), v_before,
    'settling a debt from savings must not move the pool');
  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_loan), 40000,
    'the recovery reduces what is owed');
  -- The member paid for it out of their own balance.
  PERFORM tests.eq(
    (SELECT COALESCE(SUM(delta), 0) FROM savings_adjustments
      WHERE target_member_id = v_a AND status = 'approved'),
    -20000, 'the borrower''s savings fall by the recovered amount');
  PERFORM tests.assert_balanced('recovery from savings');

  -- =============================================== 6. write-off
  -- The cash left when the loan was disbursed and is not coming back, so the pool
  -- is already correct and must NOT fall a second time.
  v_before := tests.pool();
  PERFORM tests.as_user(v_admin);
  v_act := request_loan_action(v_loan, 'write_off', 'test write-off', NULL, NULL);
  PERFORM tests.as_owner();

  PERFORM tests.eq(tests.pool(), v_before,
    'a write-off does not take the money out twice');
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan), 'written_off', 'loan written off');
  PERFORM tests.eq((SELECT outstanding_loans_tzs FROM v_group_assets), 0,
    'a written-off loan stops counting as an asset');
  PERFORM tests.eq(
    (SELECT COALESCE(SUM(amount), 0) FROM earnings_ledger WHERE kind = 'write_off'),
    -40000, 'the loss is booked against earnings');
  PERFORM tests.assert_balanced('a write-off');

  -- =============================================== 7. withdrawal
  v_before := tests.pool();
  PERFORM tests.as_user(v_admin);
  v_wd := admin_request_withdrawal(v_b, 50000, 'school fees');
  PERFORM tests.as_owner();
  PERFORM tests.eq(tests.pool(), v_before, 'requesting a withdrawal moves nothing');

  PERFORM tests.as_user(v_admin);
  PERFORM approve_withdrawal(v_wd);
  PERFORM tests.as_owner();
  PERFORM tests.eq(tests.pool(), v_before, 'approving a withdrawal still moves nothing');

  PERFORM tests.as_user(v_admin);
  PERFORM mark_withdrawal_paid(v_wd, 'test://payout');
  PERFORM tests.as_owner();
  PERFORM tests.eq(tests.pool() - v_before, -50000,
    'the pool falls only when the payout is actually recorded');
  PERFORM tests.eq((SELECT status FROM withdrawal_requests WHERE id = v_wd), 'paid', 'marked paid');
  PERFORM tests.assert_balanced('a withdrawal payout');
END;
$$;
