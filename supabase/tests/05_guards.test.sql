-- 05_guards.test.sql — the governance gates and the withdrawal collateral cap.
--
-- Note the multi-admin setup. Every other test file uses a single admin, where
-- required_approvals() falls back to 1 and the two-signature logic is never
-- exercised at all. This file is the only place the real 2-of-N path runs, which
-- makes it the only place a regression in it would be caught.

DO $$
DECLARE
  v_a1     uuid;
  v_a2     uuid;
  v_a3     uuid;
  v_member uuid;
  v_funder uuid;
  v_fee    uuid;
  v_sub    uuid;
  v_loan   uuid;
  v_req    uuid;
  v_wd     uuid;
  v_limits record;
BEGIN
  v_a1     := tests.make_admin('Guard Admin One');
  v_a2     := tests.make_admin('Guard Admin Two');
  v_a3     := tests.make_admin('Guard Admin Three');
  v_member := tests.make_member('Guard Member');
  v_funder := tests.make_member('Guard Funder');

  PERFORM tests.eq(required_approvals(), 2, 'three admins means two signatures');

  -- ==================================================== 2-of-N on a payment
  v_fee := tests.give_fee(v_member, date_trunc('month', today_eat())::date);
  v_sub := tests.submit_payment(v_member, 'monthly_fee', v_fee, 10000);

  PERFORM tests.as_user(v_a1);
  PERFORM approve_submission(v_sub, 10000);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM payment_submissions WHERE id = v_sub), 'pending',
    'one signature is not enough');
  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee), 'pending',
    'the money has not moved on one signature');

  -- The same admin cannot sign twice to reach the threshold alone.
  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT approve_submission(%L, 10000) $q$, v_sub),
    'an admin cannot approve the same submission twice');
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_a2);
  PERFORM approve_submission(v_sub, 10000);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM payment_submissions WHERE id = v_sub), 'approved',
    'the second signature finalizes it');
  PERFORM tests.eq((SELECT amount_paid FROM monthly_fees WHERE id = v_fee), 10000,
    'and the money moves');

  -- ==================================================== nobody approves their own
  -- An admin is also a contributing member, so this matters in practice.
  v_fee := tests.give_fee(v_a1, date_trunc('month', today_eat())::date);
  v_sub := tests.submit_payment(v_a1, 'monthly_fee', v_fee, 10000);
  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT approve_submission(%L, 10000) $q$, v_sub),
    'an admin cannot approve their own payment');
  PERFORM tests.as_owner();

  -- ==================================================== requester never auto-votes
  PERFORM tests.as_user(v_a1);
  v_req := request_pool_edit(50000, 'test adjustment');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM pool_adjustments WHERE id = v_req), 'pending',
    'opening a request does not count as approving it');

  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT approve_pool_edit(%L) $q$, v_req),
    'the requester cannot approve their own pool edit');
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_a2);
  PERFORM approve_pool_edit(v_req);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM pool_adjustments WHERE id = v_req), 'pending',
    'still one short');

  PERFORM tests.as_user(v_a3);
  PERFORM approve_pool_edit(v_req);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM pool_adjustments WHERE id = v_req), 'approved',
    'two OTHER admins carry it');

  -- ==================================================== a loan and its collateral
  PERFORM tests.give_savings(v_funder, 900000);
  PERFORM tests.give_savings(v_member, 100000);

  INSERT INTO loans (member_id, principal, status)
  VALUES (v_member, 90000, 'pending') RETURNING id INTO v_loan;
  PERFORM tests.as_user(v_a1);
  PERFORM approve_loan(v_loan, 'test://d');
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2);
  PERFORM approve_loan(v_loan, 'test://d');
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan), 'active',
    'a loan also needs two signatures');

  -- Savings are the security behind the loan: at a 5x cap, a 90,000 balance
  -- outstanding locks 18,000 of the borrower's own money.
  SELECT * INTO v_limits FROM member_withdrawable(v_member);
  -- 100,000 deposited + the 10,000 fee settled at the top of this file. Paid fees
  -- ARE savings (migration 014), which is easy to forget when reading a balance.
  PERFORM tests.eq(v_limits.savings_tzs, 110000, 'paid fees count toward savings');
  PERFORM tests.eq(v_limits.outstanding_tzs, 90000, 'outstanding is reported');
  PERFORM tests.eq(v_limits.locked_tzs, 18000, 'outstanding / multiplier is locked');
  PERFORM tests.eq(v_limits.withdrawable_tzs, 92000, 'the rest is withdrawable');

  -- Withdrawals are raised by an admin on the member's behalf (036). The ceiling
  -- is the member's, not the admin's — that is the part worth pinning.
  PERFORM tests.as_user(v_member);
  PERFORM tests.raises(format($q$ SELECT admin_request_withdrawal(%L, 1, 'x') $q$, v_member),
    'a member cannot raise their own withdrawal');
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT admin_request_withdrawal(%L, 92001, 'too much') $q$,
      v_member),
    'not even an admin can withdraw the savings securing a loan');
  v_wd := admin_request_withdrawal(v_member, 92000, 'right up to the cap');
  PERFORM tests.as_owner();

  -- Committed-but-unpaid money is not available a second time.
  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT admin_request_withdrawal(%L, 1, 'again') $q$, v_member),
    'a member cannot have a second withdrawal while one is in flight');
  PERFORM tests.as_owner();

  -- ==================================================== withdrawal approvals
  PERFORM tests.as_user(v_a1);
  PERFORM approve_withdrawal(v_wd);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM withdrawal_requests WHERE id = v_wd), 'pending',
    'one signature does not authorise a payout');

  PERFORM tests.as_user(v_a2);
  PERFORM approve_withdrawal(v_wd);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM withdrawal_requests WHERE id = v_wd), 'approved',
    'two signatures authorise it');

  -- ==================================================== loan actions
  -- The borrower must never vote on what happens to their own debt.
  PERFORM tests.as_user(v_a1);
  v_req := request_loan_action(v_loan, 'write_off', 'test', NULL, NULL);
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT approve_loan_action(%L) $q$, v_req),
    'the requester cannot approve their own loan action');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan), 'active',
    'the loan is untouched until the threshold is met');

  -- ==================================================== exit needs a settled loan
  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT request_member_exit(%L, 'leaving') $q$, v_member),
    'a member cannot walk away from an open loan');
  PERFORM tests.raises(format($q$ SELECT request_member_exit(%L, 'leaving') $q$, v_a1),
    'an admin cannot process their own exit');
  PERFORM tests.as_owner();

  -- ==================================================== members are not admins
  PERFORM tests.as_user(v_member);
  PERFORM tests.raises(format($q$ SELECT approve_submission(%L, 1) $q$, v_sub),
    'a member cannot approve payments');
  PERFORM tests.raises(format($q$ SELECT approve_loan(%L, 'x') $q$, v_loan),
    'a member cannot approve loans');
  PERFORM tests.raises($q$ SELECT request_pool_edit(1, 'x') $q$,
    'a member cannot adjust the pool');
  PERFORM tests.as_owner();

  -- ==================================================== the views scope per member
  -- 003_rls_policies.sql:50 claimed these scoped by RLS "(security_invoker default)",
  -- but views default to the OWNER's rights and bypass RLS entirely. Migration 027
  -- sets the flag; this is the assertion that keeps it set.
  PERFORM tests.give_fee(v_funder, (date_trunc('month', today_eat()) - INTERVAL '1 month')::date);
  PERFORM tests.give_fee(v_member, (date_trunc('month', today_eat()) - INTERVAL '1 month')::date);

  PERFORM tests.as_user(v_member);
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM v_fee_status_money WHERE member_id <> v_member),
    0, 'a member cannot read another member''s fees through the money view');
  IF (SELECT count(*) FROM v_fee_status_money) = 0 THEN
    RAISE EXCEPTION 'the member cannot see their OWN fees either — the view is over-restricted';
  END IF;

  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM v_installment_status_money i
      JOIN loans l ON l.id = i.loan_id WHERE l.member_id <> v_member),
    0, 'nor another member''s installments');
  PERFORM tests.as_owner();

  -- An admin still sees everything: the policies are `own row OR is_admin()`.
  PERFORM tests.as_user(v_a3);
  IF (SELECT count(*) FROM v_fee_status_money WHERE member_id = v_member) = 0 THEN
    RAISE EXCEPTION 'security_invoker broke admin visibility';
  END IF;
  PERFORM tests.as_owner();
END;
$$;
