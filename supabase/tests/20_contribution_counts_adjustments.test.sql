-- 20_contribution_counts_adjustments.test.sql — approve_loan's contribution arm
-- is the savings the member is actually shown (047).
--
-- The property that matters: one definition of savings. A member reading their
-- own dashboard, an admin reading the approval card, and the RPC that decides
-- whether the loan may be disbursed must all be looking at the same number. They
-- were not — approve_loan carried the 005 wording, which predates both
-- savings_adjustments (013) and partial fee payments (021), so a balance recorded
-- as an adjustment was invisible to the one function that could refuse a loan
-- over it.
--
-- Each block below fails loudly against the pre-047 function: the first because
-- an adjustment-only member had a ceiling of zero, the second because a clawback
-- left the defaulter's ceiling untouched, the third because a part-settled fee
-- counted for nothing.

DO $$
DECLARE
  v_a1   uuid;
  v_a2   uuid;
  v_m1   uuid;
  v_m2   uuid;
  v_m3   uuid;
  v_loan uuid;
BEGIN
  v_a1 := tests.make_admin('Contribution Admin One');
  v_a2 := tests.make_admin('Contribution Admin Two');
  v_m1 := tests.make_member('Contribution Adjustment Only');
  v_m2 := tests.make_member('Contribution Clawback');
  v_m3 := tests.make_member('Contribution Part Paid Fee');

  -- Two members funded the ordinary way, purely to give the group enough assets
  -- that the 25% arm is never what refuses anything below.
  PERFORM tests.give_savings(v_m2, 2000000);
  PERFORM tests.give_savings(v_m3, 2000000);
  PERFORM tests.eq(tests.pool(), 4000000, 'pool from the two deposit members');

  -- ================================================== an adjustment IS savings

  -- m1 has no deposits at all. Their entire balance is an approved adjustment —
  -- exactly how operations/2026-09-29_savings_opening_balance_230k.sql records
  -- an opening balance the group asserts rather than a payment anybody filed.
  INSERT INTO savings_adjustments (target_member_id, delta, reason, status, applied_at)
  VALUES (v_m1, 300000, 'opening balance the group asserted', 'approved', now());

  PERFORM tests.eq(member_savings(v_m1), 300000,
                   'an approved adjustment is the member''s savings');
  -- The member-facing directory and the loan RPC read the same figure. Before
  -- 047 these two disagreed, which is the whole defect.
  PERFORM tests.eq((SELECT savings_tzs FROM group_member_directory()
                     WHERE member_id = v_m1),
                   member_savings(v_m1),
                   'the directory and member_savings agree');
  PERFORM tests.eq(tests.pool(), 4300000, 'an approved adjustment is cash in the pool');

  -- THE TEST. 5x 300,000 is 1,500,000 and 25% of 4,300,000 is 1,075,000, so
  -- 1,000,000 clears both arms. Pre-047 approve_loan measured m1 at zero and
  -- refused this with "max 0".
  INSERT INTO loans (member_id, principal, status)
  VALUES (v_m1, 1000000, 'pending') RETURNING id INTO v_loan;
  PERFORM tests.as_user(v_a1); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT count(*)::numeric FROM loans WHERE id = v_loan AND status = 'active'),
                   1, 'a member funded only by an adjustment can borrow against it');
  PERFORM tests.assert_balanced('the adjustment-funded loan');

  -- The audit row carries the figure the ceiling was measured against (047), so
  -- a later dispute does not have to rebuild it from three tables.
  PERFORM tests.eq((SELECT (details->>'contribution')::numeric FROM audit_log
                     WHERE action = 'approve_loan' AND target_id = v_loan),
                   300000, 'the audit row records the contribution used');

  -- ============================================ a clawback LOWERS the ceiling

  -- A loan recovery books a negative adjustment (022). Pre-047 that money was
  -- still counted toward the defaulter's next ceiling — the same bug, pointing
  -- the other way, and the expensive direction.
  INSERT INTO savings_adjustments (target_member_id, delta, reason, status, applied_at)
  VALUES (v_m2, -1900000, 'savings applied to settle a defaulted loan', 'approved', now());

  PERFORM tests.eq(member_savings(v_m2), 100000, 'a clawback comes off savings');
  -- pool 4,300,000 - 1,000,000 lent - 1,900,000 clawed back
  PERFORM tests.eq(tests.pool(), 1400000, 'pool after the clawback');
  PERFORM tests.eq((SELECT total_assets_tzs FROM v_group_assets), 2400000,
                   'assets after the clawback');

  -- 25% of 2,400,000 is 600,000 and the pool holds 1,400,000, so neither of
  -- those arms can be what refuses 550,000. Only the contribution arm can:
  -- 5x 100,000 is 500,000.
  INSERT INTO loans (member_id, principal, status)
  VALUES (v_m2, 550000, 'pending') RETURNING id INTO v_loan;
  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(
    format('SELECT approve_loan(%L, %L)', v_loan, 'test://d'),
    'a loan above the clawed-back ceiling is refused');
  PERFORM tests.as_owner();

  -- And 500,000 — exactly the ceiling — goes through, which is what proves the
  -- refusal above was the contribution arm and not the assets arm or the pool.
  UPDATE loans SET principal = 500000 WHERE id = v_loan;
  PERFORM tests.as_user(v_a1); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT count(*)::numeric FROM loans WHERE id = v_loan AND status = 'active'),
                   1, 'a loan exactly at the clawed-back ceiling is allowed');
  PERFORM tests.assert_balanced('the loan at the clawed-back ceiling');

  -- ======================================== a PART-SETTLED fee is savings too

  -- Since 021 a fee can be half paid, and the app has counted amount_paid ever
  -- since. approve_loan read `amount` on rows marked 'paid', so this 40,000 —
  -- real money, already banked — was worth nothing to the borrower.
  INSERT INTO monthly_fees (member_id, period, amount, amount_paid, status)
  VALUES (v_m3, date_trunc('month', today_eat())::date, 100000, 40000, 'partial');

  PERFORM tests.eq(member_savings(v_m3), 2040000,
                   'money banked against an unsettled fee is savings');
  PERFORM tests.eq((SELECT savings_tzs FROM group_member_directory()
                     WHERE member_id = v_m3),
                   member_savings(v_m3),
                   'the directory and member_savings agree on a part-paid fee');

  RAISE NOTICE '20_contribution_counts_adjustments: ok';
END;
$$;
