-- 06_guarantors.test.sql — co-signers, the pledge lock, and calling (migration 028).
--
-- The property that matters most: an accepted pledge must actually LOCK the
-- guarantor's savings. A guarantee that does not stop the guarantor withdrawing
-- the money they promised is decoration, not security — and nothing on screen
-- would ever reveal the difference.

DO $$
DECLARE
  v_admin uuid;
  v_borrower uuid;
  v_g1     uuid;
  v_g2     uuid;
  v_funder uuid;
  v_loan   uuid;
  v_n1     uuid;
  v_n2     uuid;
  v_before numeric;
  v_limits record;
  v_called numeric;
BEGIN
  v_admin    := tests.make_admin('Guarantor Admin');
  v_borrower := tests.make_member('Guarantor Borrower');
  v_g1       := tests.make_member('Guarantor One');
  v_g2       := tests.make_member('Guarantor Two');
  v_funder   := tests.make_member('Guarantor Funder');

  PERFORM tests.give_savings(v_funder,   900000);
  PERFORM tests.give_savings(v_borrower, 100000);
  PERFORM tests.give_savings(v_g1,       100000);
  PERFORM tests.give_savings(v_g2,       100000);

  INSERT INTO loans (member_id, principal, status)
  VALUES (v_borrower, 90000, 'pending') RETURNING id INTO v_loan;

  -- ==================================================== nominating
  PERFORM tests.as_user(v_borrower);
  PERFORM tests.raises(
    format($q$ SELECT nominate_guarantor(%L, %L, 1000) $q$, v_loan, v_borrower),
    'a borrower cannot guarantee their own loan');
  PERFORM tests.raises(
    format($q$ SELECT nominate_guarantor(%L, %L, 999999) $q$, v_loan, v_g1),
    'nobody can pledge more than their free savings');

  v_n1 := nominate_guarantor(v_loan, v_g1, 40000);
  v_n2 := nominate_guarantor(v_loan, v_g2, 20000);
  PERFORM tests.as_owner();

  -- Only the borrower nominates.
  PERFORM tests.as_user(v_g1);
  PERFORM tests.raises(
    format($q$ SELECT nominate_guarantor(%L, %L, 1000) $q$, v_loan, v_funder),
    'a third party cannot nominate guarantors for someone else''s loan');
  PERFORM tests.as_owner();

  -- ==================================================== approval is blocked
  PERFORM tests.as_user(v_admin);
  PERFORM tests.raises(format($q$ SELECT approve_loan(%L, 'x') $q$, v_loan),
    'a loan cannot be approved while a guarantor has not answered');
  PERFORM tests.as_owner();

  -- A pledge only binds once accepted, so a pending one locks nothing.
  SELECT * INTO v_limits FROM member_withdrawable(v_g1);
  PERFORM tests.eq(v_limits.locked_tzs, 0, 'an unanswered nomination locks nothing');

  -- ==================================================== accepting locks savings
  PERFORM tests.as_user(v_g1);
  PERFORM respond_to_guarantee(v_n1, true);
  PERFORM tests.as_owner();

  SELECT * INTO v_limits FROM member_withdrawable(v_g1);
  PERFORM tests.eq(v_limits.locked_tzs, 40000, 'an accepted pledge locks that much');
  PERFORM tests.eq(v_limits.withdrawable_tzs, 60000, 'only the free balance is withdrawable');

  PERFORM tests.as_user(v_g1);
  PERFORM tests.raises($q$ SELECT request_withdrawal(60001, 'too much') $q$,
    'a guarantor cannot withdraw the savings they have pledged');
  PERFORM tests.as_owner();

  -- Only the nominated member can answer.
  PERFORM tests.as_user(v_funder);
  PERFORM tests.raises(format($q$ SELECT respond_to_guarantee(%L, true) $q$, v_n2),
    'only the nominated guarantor can respond');
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_g2);
  PERFORM respond_to_guarantee(v_n2, true);
  PERFORM tests.raises(format($q$ SELECT respond_to_guarantee(%L, false) $q$, v_n2),
    'a guarantor cannot change their answer');
  PERFORM tests.as_owner();

  -- ==================================================== approval now proceeds
  PERFORM tests.as_user(v_admin);
  PERFORM approve_loan(v_loan, 'test://d');
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan), 'active',
    'with every guarantor answered, the loan can be approved');
  PERFORM tests.assert_balanced('a guaranteed loan being disbursed');

  -- ==================================================== calling the guarantees
  PERFORM tests.as_user(v_admin);
  PERFORM tests.raises(format($q$ SELECT call_guarantees(%L, 'too early') $q$, v_loan),
    'guarantees cannot be called before the loan is written off');

  PERFORM request_loan_action(v_loan, 'write_off', 'borrower disappeared', NULL, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan), 'written_off', 'written off');
  PERFORM tests.assert_balanced('the write-off');

  v_before := tests.pool();
  PERFORM tests.as_user(v_admin);
  v_called := call_guarantees(v_loan, 'recovering from the guarantors');
  PERFORM tests.as_owner();

  -- 90,000 lost against 60,000 pledged: each guarantor pays their full pledge and
  -- no more, so the group still eats the remaining 30,000.
  PERFORM tests.eq(v_called, 60000, 'each guarantor pays their pledge, capped at it');
  PERFORM tests.eq(
    (SELECT COALESCE(SUM(delta), 0) FROM savings_adjustments
      WHERE target_member_id = v_g1 AND status = 'approved'),
    -40000, 'the first guarantor''s savings fall by their pledge');
  PERFORM tests.eq(
    (SELECT COALESCE(SUM(delta), 0) FROM savings_adjustments
      WHERE target_member_id = v_g2 AND status = 'approved'),
    -20000, 'the second guarantor''s by theirs');

  -- No cash moved: savings became loan recovery, exactly as in 022.
  PERFORM tests.eq(tests.pool(), v_before, 'calling a guarantee moves no cash');
  PERFORM tests.assert_balanced('calling the guarantees');

  -- The group's net loss is now only the uncovered part.
  PERFORM tests.eq(
    (SELECT COALESCE(SUM(amount), 0) FROM earnings_ledger
      WHERE kind = 'write_off' AND source_id = v_loan),
    -30000, 'recovery reduces the recorded loss to the uncovered shortfall');

  -- Called pledges stop locking anything.
  SELECT * INTO v_limits FROM member_withdrawable(v_g1);
  PERFORM tests.eq(v_limits.locked_tzs, 0, 'a called pledge no longer locks savings');
  PERFORM tests.eq(v_limits.savings_tzs, 60000, 'their balance is genuinely reduced');

  -- ==================================================== release on repayment
  -- A guarantor on a loan that is simply repaid must be freed automatically.
  DECLARE
    v_loan2 uuid;
    v_n3    uuid;
  BEGIN
    INSERT INTO loans (member_id, principal, status)
    VALUES (v_funder, 30000, 'pending') RETURNING id INTO v_loan2;

    PERFORM tests.as_user(v_funder);
    v_n3 := nominate_guarantor(v_loan2, v_g2, 10000);
    PERFORM tests.as_owner();
    PERFORM tests.as_user(v_g2);
    PERFORM respond_to_guarantee(v_n3, true);
    PERFORM tests.as_owner();

    SELECT * INTO v_limits FROM member_withdrawable(v_g2);
    PERFORM tests.eq(v_limits.locked_tzs, 10000, 'the new pledge locks');

    UPDATE loans SET status = 'closed' WHERE id = v_loan2;

    PERFORM tests.eq((SELECT status FROM loan_guarantors WHERE id = v_n3), 'released',
      'closing a loan releases its guarantees automatically');
    SELECT * INTO v_limits FROM member_withdrawable(v_g2);
    PERFORM tests.eq(v_limits.locked_tzs, 0, 'and unlocks the savings');
  END;
END;
$$;
