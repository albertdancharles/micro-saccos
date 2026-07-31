-- 07_reports.test.sql — the AGM accounts (migration 029).
--
-- The property that matters: the balance sheet must reconcile. If it can disagree
-- with v_pool_reconciliation the group has two sets of books, and the one they read
-- at the annual meeting is the one they will believe.

DO $$
DECLARE
  v_admin  uuid;
  v_a      uuid;
  v_b      uuid;
  v_fee    uuid;
  v_sub    uuid;
  v_loan   uuid;
  v_inst   uuid;
  v_pen    numeric;
  v_r      record;
  v_rows   int;
BEGIN
  v_admin := tests.make_admin('Report Admin');
  v_a     := tests.make_member('Report Alice');
  v_b     := tests.make_member('Report Bob');

  PERFORM tests.give_savings(v_a, 600000);
  PERFORM tests.give_savings(v_b, 400000);

  -- A fee paid late: base is Alice's capital, the penalty is the group's income.
  v_fee := tests.give_fee(v_a, (date_trunc('month', today_eat()) - INTERVAL '2 months')::date);
  SELECT penalty_due INTO v_pen FROM v_fee_status_money WHERE id = v_fee;
  v_sub := tests.submit_payment(v_a, 'monthly_fee', v_fee, v_pen + 10000);
  PERFORM tests.as_user(v_admin);
  PERFORM approve_submission(v_sub, v_pen + 10000);
  PERFORM tests.as_owner();

  -- A loan, and one interest payment on it.
  INSERT INTO loans (member_id, principal, status)
  VALUES (v_b, 100000, 'pending') RETURNING id INTO v_loan;
  PERFORM tests.as_user(v_admin);
  PERFORM approve_loan(v_loan, 'test://d');
  PERFORM tests.as_owner();

  SELECT id INTO v_inst FROM loan_installments WHERE loan_id = v_loan AND installment_number = 1;
  v_sub := tests.submit_payment(v_b, 'loan_installment', v_inst, 5000);
  PERFORM tests.as_user(v_admin);
  PERFORM approve_submission(v_sub, 5000);
  PERFORM tests.as_owner();

  -- ==================================================== income statement
  SELECT * INTO v_r FROM group_income_statement(
    (today_eat() - INTERVAL '1 year')::date, today_eat());

  PERFORM tests.eq(v_r.interest_tzs, 5000, 'interest collected is income');
  PERFORM tests.eq(v_r.penalty_tzs, v_pen, 'penalties collected are income');
  PERFORM tests.eq(v_r.net_tzs, 5000 + v_pen, 'net is the sum of both');
  PERFORM tests.eq(v_r.loans_issued, 1, 'one loan was issued');
  PERFORM tests.eq(v_r.loans_issued_tzs, 100000, 'for 100,000');
  -- The 10,000 fee base is capital, not profit. Reporting it as income would make
  -- a group that only collects fees look like it is making money.
  PERFORM tests.eq(v_r.fees_collected_tzs, v_pen + 10000, 'fee cash is reported separately');

  -- A window with nothing in it must report zeros, not nulls.
  SELECT * INTO v_r FROM group_income_statement(DATE '2000-01-01', DATE '2000-12-31');
  PERFORM tests.eq(v_r.net_tzs, 0, 'an empty period earns nothing');
  PERFORM tests.eq(v_r.loans_issued, 0, 'and issues nothing');

  -- ==================================================== balance sheet
  SELECT * INTO v_r FROM group_balance_sheet(NULL);
  PERFORM tests.eq(v_r.difference_tzs, 0, 'the balance sheet balances');
  PERFORM tests.eq(v_r.total_assets_tzs, v_r.total_claims_tzs, 'assets equal claims');

  -- And it must agree with the reconciliation view, or the group has two truths.
  PERFORM tests.eq(
    v_r.total_assets_tzs,
    (SELECT total_assets_tzs FROM v_pool_reconciliation),
    'the balance sheet agrees with v_pool_reconciliation');
  PERFORM tests.assert_balanced('building the reports');

  PERFORM tests.eq(v_r.outstanding_tzs, 100000, 'the loan is an asset while it is out');

  -- ==================================================== member ledger
  PERFORM tests.as_user(v_a);
  SELECT count(*) INTO v_rows FROM member_ledger(v_a, NULL, NULL);
  IF v_rows = 0 THEN RAISE EXCEPTION 'the ledger should show Alice''s movements'; END IF;

  -- The running balance ends at the member's actual capital: 600,000 deposited
  -- plus the 10,000 fee base (the penalty portion is the group's, not hers).
  PERFORM tests.eq(
    (SELECT SUM(amount) FROM member_ledger(v_a, NULL, NULL)),
    610000, 'the movements sum to the member''s capital');

  -- The closing balance must equal that sum. Ordered by the same key as the
  -- window function — a deposit and a fee approved in the same transaction share
  -- a timestamp, so `ORDER BY occurred_at` alone picks between them arbitrarily.
  PERFORM tests.eq(
    (SELECT balance FROM member_ledger(v_a, NULL, NULL)
      ORDER BY occurred_at DESC, kind DESC LIMIT 1),
    610000, 'and the running balance closes there');

  -- A member must not be able to read anyone else's ledger.
  PERFORM tests.raises(format($q$ SELECT * FROM member_ledger(%L, NULL, NULL) $q$, v_b),
    'a member cannot read another member''s ledger');
  PERFORM tests.as_owner();

  -- An admin can.
  PERFORM tests.as_user(v_admin);
  SELECT count(*) INTO v_rows FROM member_ledger(v_b, NULL, NULL);
  IF v_rows = 0 THEN RAISE EXCEPTION 'an admin should see any member''s ledger'; END IF;
  PERFORM tests.as_owner();

  -- ==================================================== member report
  PERFORM tests.eq(
    (SELECT capital_tzs FROM group_member_report(NULL) WHERE member_id = v_a),
    610000, 'the member report agrees with the ledger');
  PERFORM tests.eq(
    (SELECT outstanding_tzs FROM group_member_report(NULL) WHERE member_id = v_b),
    100000, 'and shows what a borrower still owes');
  PERFORM tests.eq(
    (SELECT penalties_tzs FROM group_member_report(NULL) WHERE member_id = v_a),
    v_pen, 'and what each member has cost the group in fines');
END;
$$;
