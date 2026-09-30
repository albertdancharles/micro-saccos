-- 19_approval_without_proof.test.sql — a loan can be approved with no
-- disbursement screenshot (046).
--
-- The property: nothing in the approval path may require a proof. The group
-- agrees its loans in the meeting and hands the money over in the room; the two
-- signatures are the control. A NULL proof must carry all the way through —
-- both signatures, the finalization, the schedule — and must not become an
-- error at any of them.
--
-- The second property, which matters just as much: a proof that IS supplied is
-- still recorded, and the FIRST approver's value still wins. 046 removed a
-- requirement, not a capability.

DO $$
DECLARE
  v_a1   uuid;
  v_a2   uuid;
  v_m1   uuid;
  v_m2   uuid;
  v_loan uuid;
BEGIN
  v_a1 := tests.make_admin('No Proof Admin One');
  v_a2 := tests.make_admin('No Proof Admin Two');
  v_m1 := tests.make_member('No Proof One');
  v_m2 := tests.make_member('No Proof Two');

  PERFORM tests.give_savings(v_m1, 1000000);
  PERFORM tests.give_savings(v_m2, 1000000);

  -- ============================================ no proof at all

  INSERT INTO loans (member_id, principal, status)
  VALUES (v_m1, 400000, 'pending') RETURNING id INTO v_loan;

  -- First signature, no screenshot. Before 046 this raised a not-null violation
  -- on loan_approvals.proof_url and the loan stayed pending.
  PERFORM tests.as_user(v_a1); PERFORM approve_loan(v_loan, NULL); PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT count(*)::numeric FROM loan_approvals WHERE loan_id = v_loan),
                   1, 'the first signature is recorded without a proof');
  PERFORM tests.eq((SELECT count(*)::numeric FROM loans WHERE id = v_loan AND status = 'pending'),
                   1, 'one signature is not enough on its own');

  -- Second signature, also none. This is the one that finalizes.
  PERFORM tests.as_user(v_a2); PERFORM approve_loan(v_loan, NULL); PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT count(*)::numeric FROM loans WHERE id = v_loan AND status = 'active'),
                   1, 'the loan goes active with no proof anywhere');
  PERFORM tests.eq((SELECT count(*)::numeric FROM loans
                     WHERE id = v_loan AND disbursement_proof_url IS NULL),
                   1, 'the loan records no proof, rather than an empty string');
  PERFORM tests.eq((SELECT count(*)::numeric FROM loan_installments WHERE loan_id = v_loan),
                   setting('default_loan_months'),
                   'the schedule is generated exactly as it is with a proof');
  PERFORM tests.assert_balanced('a loan approved without a proof');

  -- The 2-of-N rule is untouched: the same admin still cannot sign twice, and
  -- that has to hold when there is no proof to tell the two calls apart.
  BEGIN
    PERFORM tests.as_user(v_a1);
    PERFORM approve_loan(v_loan, NULL);
    PERFORM tests.as_owner();
    RAISE EXCEPTION 'an admin approved the same loan twice';
  EXCEPTION WHEN OTHERS THEN
    PERFORM tests.as_owner();
  END;

  -- ============================================ a proof still works

  INSERT INTO loans (member_id, principal, status)
  VALUES (v_m2, 400000, 'pending') RETURNING id INTO v_loan;

  PERFORM tests.as_user(v_a1); PERFORM approve_loan(v_loan, 'test://first'); PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2); PERFORM approve_loan(v_loan, 'test://second'); PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT count(*)::numeric FROM loans
                     WHERE id = v_loan AND disbursement_proof_url = 'test://first'),
                   1, 'the first approver''s proof is still the one recorded');
  PERFORM tests.assert_balanced('a loan approved with a proof');

  RAISE NOTICE 'approval without proof tests passed';
END $$;
