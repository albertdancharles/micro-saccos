-- 18_loan_cap_on_assets.test.sql — the 25% cap is a share of group ASSETS (045).
--
-- The property that matters: a member's ceiling must not depend on how much the
-- group happens to have already lent out this meeting. Lending moves money from
-- the pool to outstanding principal; it does not make the group poorer, so it
-- must not make the next borrower's ceiling smaller. Before 045 it did, and the
-- same amount was allowed at the top of a meeting's agenda and refused at the
-- bottom.
--
-- The second property, which 045 had to add: assets >= pool, so a cap measured
-- against assets no longer guarantees the cash is there. The pool must be
-- checked on its own or v_group_pool goes negative.

DO $$
DECLARE
  v_a1  uuid;
  v_a2  uuid;
  v_m1  uuid;
  v_m2  uuid;
  v_m3  uuid;
  v_m4  uuid;
  v_m5  uuid;
  v_loan uuid;
  v_msg  text;
  v_assets numeric;
BEGIN
  v_a1 := tests.make_admin('Assets Cap Admin One');
  v_a2 := tests.make_admin('Assets Cap Admin Two');
  v_m1 := tests.make_member('Assets Cap One');
  v_m2 := tests.make_member('Assets Cap Two');
  v_m3 := tests.make_member('Assets Cap Three');
  v_m4 := tests.make_member('Assets Cap Four');
  v_m5 := tests.make_member('Assets Cap Five');

  -- 1,000,000 each: the 5x contribution arm is 5,000,000, far above anything
  -- borrowed here, so every refusal below is the assets arm or the pool, never
  -- the contribution arm.
  PERFORM tests.give_savings(v_m1, 1000000);
  PERFORM tests.give_savings(v_m2, 1000000);
  PERFORM tests.give_savings(v_m3, 1000000);
  PERFORM tests.give_savings(v_m4, 1000000);

  PERFORM tests.eq(tests.pool(), 4000000, 'pool before any lending');
  PERFORM tests.eq((SELECT total_assets_tzs FROM v_group_assets), 4000000,
                   'assets before any lending');

  -- ============================================ the cap does not shrink

  -- Loan 1 of 1,000,000 = exactly 25% of 4,000,000. Allowed under either rule.
  INSERT INTO loans (member_id, principal, status)
  VALUES (v_m1, 1000000, 'pending') RETURNING id INTO v_loan;
  PERFORM tests.as_user(v_a1); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT count(*)::numeric FROM loans WHERE id = v_loan AND status = 'active'),
                   1, 'first loan is active');
  PERFORM tests.assert_balanced('the first loan');

  -- The pool has fallen; the group has not.
  PERFORM tests.eq(tests.pool(), 3000000, 'pool after the first loan');
  PERFORM tests.eq((SELECT total_assets_tzs FROM v_group_assets), 4000000,
                   'assets are unchanged by lending');

  -- THE TEST. 25% of the POOL is now 750,000, so the old rule would refuse this
  -- 1,000,000. 25% of ASSETS is still 1,000,000, so 045 allows it. If this
  -- statement raises, the cap is being measured against the pool again.
  INSERT INTO loans (member_id, principal, status)
  VALUES (v_m2, 1000000, 'pending') RETURNING id INTO v_loan;
  PERFORM tests.as_user(v_a1); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT count(*)::numeric FROM loans WHERE id = v_loan AND status = 'active'),
                   1, 'the second borrower gets the same ceiling as the first');
  PERFORM tests.assert_balanced('the second loan');

  -- And again, twice more, down to an empty pool. Every one of these would have
  -- been refused by the old rule; none of them changes what the group is worth.
  INSERT INTO loans (member_id, principal, status)
  VALUES (v_m3, 1000000, 'pending') RETURNING id INTO v_loan;
  PERFORM tests.as_user(v_a1); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();

  INSERT INTO loans (member_id, principal, status)
  VALUES (v_m4, 1000000, 'pending') RETURNING id INTO v_loan;
  PERFORM tests.as_user(v_a1); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();

  PERFORM tests.eq(tests.pool(), 0, 'the pool is empty');
  PERFORM tests.eq((SELECT total_assets_tzs FROM v_group_assets), 4000000,
                   'the group is worth exactly what it was before it lent anything');
  PERFORM tests.assert_balanced('lending the whole pool');

  -- ============================================ the two refusals

  -- New money, so the pool is not zero and the two checks can be told apart.
  PERFORM tests.give_savings(v_m5, 1000000);
  SELECT total_assets_tzs INTO v_assets FROM v_group_assets;
  PERFORM tests.eq(v_assets, 5000000, 'assets after the fifth deposit');
  PERFORM tests.eq(tests.pool(), 1000000, 'pool after the fifth deposit');
  -- Ceiling is now floor(0.25 * 5,000,000) = 1,250,000.

  -- Over the cap: refused for being too big a share of the group, and it must be
  -- THAT message even though the pool could not cover it either — the assets
  -- check runs first, and the two say different things.
  INSERT INTO loans (member_id, principal, status)
  VALUES (v_m5, 1300000, 'pending') RETURNING id INTO v_loan;
  BEGIN
    PERFORM tests.as_user(v_a1);
    PERFORM approve_loan(v_loan, 'test://d');
    PERFORM tests.as_owner();
    RAISE EXCEPTION 'a loan over 25%% of assets was approved';
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    PERFORM tests.as_owner();
  END;
  IF v_msg NOT LIKE '%total assets%' THEN
    RAISE EXCEPTION 'over-cap loan refused for the wrong reason: %', v_msg;
  END IF;
  PERFORM tests.eq((SELECT count(*)::numeric FROM loans WHERE id = v_loan AND status = 'pending'),
                   1, 'the over-cap loan is still pending');

  -- Under the cap but over the cash: refused for liquidity, in its own words.
  -- 1,200,000 <= 1,250,000 (the cap) and <= 5,000,000 (5x contribution), so the
  -- only thing that can stop it is the pool's 1,000,000.
  INSERT INTO loans (member_id, principal, status)
  VALUES (v_m5, 1200000, 'pending') RETURNING id INTO v_loan;
  BEGIN
    PERFORM tests.as_user(v_a1);
    PERFORM approve_loan(v_loan, 'test://d');
    PERFORM tests.as_owner();
    RAISE EXCEPTION 'a loan larger than the pool was approved';
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    PERFORM tests.as_owner();
  END;
  IF v_msg NOT LIKE '%pool holds only%' THEN
    RAISE EXCEPTION 'over-cash loan refused for the wrong reason: %', v_msg;
  END IF;

  -- Exactly the cash available, and under the cap: allowed.
  INSERT INTO loans (member_id, principal, status)
  VALUES (v_m5, 1000000, 'pending') RETURNING id INTO v_loan;
  PERFORM tests.as_user(v_a1); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();
  PERFORM tests.as_user(v_a2); PERFORM approve_loan(v_loan, 'test://d'); PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT count(*)::numeric FROM loans WHERE id = v_loan AND status = 'active'),
                   1, 'a loan for exactly the pool balance is allowed');
  PERFORM tests.eq(tests.pool(), 0, 'the pool is empty again');
  PERFORM tests.assert_balanced('the last loan');

  -- The pool never went negative at any point above.
  IF tests.pool() < 0 THEN
    RAISE EXCEPTION 'the pool is negative: %', tests.pool();
  END IF;

  -- ============================================ the rule as written down

  PERFORM tests.eq(
    (SELECT label FROM group_settings WHERE key = 'pool_loan_fraction'),
    'Max share of group assets per loan',
    'the setting says what it now means'
  );
  PERFORM tests.eq(setting('pool_loan_fraction'), 0.25, 'the fraction itself is unchanged');

  RAISE NOTICE 'loan cap on group assets tests passed';
END $$;
