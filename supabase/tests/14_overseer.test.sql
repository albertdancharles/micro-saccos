-- 14_overseer.test.sql — the single unrestricted admin (041).
--
-- Two things are under test and the second matters as much as the first.
--
-- WHAT THE OVERSEER GAINS: one signature is a quorum. Every 2-of-N flow in this
-- schema routes through required_approvals(), so the tests below check the
-- OUTCOME of a request rather than the return value of that function — a request
-- that executes inside its own call is the only proof the bypass reaches all the
-- way through.
--
-- WHAT THE OVERSEER CANNOT DO: the office cannot be handed out from inside the
-- app, and cannot be taken away from inside it either. `Admin can update any
-- profile` (003) has no WITH CHECK, so without protect_overseer() every admin
-- could write the flag onto themselves. Section D is that hole, tested.

-- ============================================================================
-- A. One signature is a quorum — and only for the overseer.
-- ============================================================================
DO $$
DECLARE
  v_over   uuid;
  v_a1     uuid;
  v_a2     uuid;
  v_change uuid;
  v_before numeric;
BEGIN
  v_over := tests.make_overseer('Ovr Overseer');
  v_a1   := tests.make_admin('OvrA Admin One');
  v_a2   := tests.make_admin('OvrA Admin Two');

  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM profiles WHERE role = 'admin' AND is_active = true),
    3, 'three admins exist, so the ordinary threshold is two');

  v_before := setting('monthly_fee_amount');

  -- An ordinary admin's setting change waits for a second signature.
  PERFORM tests.as_user(v_a1);
  v_change := request_setting_change('monthly_fee_amount', v_before + 1000, 'Ordinary admin');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM setting_changes WHERE id = v_change), 'pending',
    'an ordinary admin cannot change a setting alone');
  PERFORM tests.eq(setting('monthly_fee_amount'), v_before,
    'and the setting itself has not moved');

  -- The overseer's does not wait. A different key, because 020 allows only one
  -- pending change per key and that guard is not what this block is testing.
  PERFORM tests.as_user(v_over);
  v_change := request_setting_change('loan_interest_rate', 0.07, 'Overseer');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM setting_changes WHERE id = v_change), 'approved',
    'the overseer changes a setting on their own signature');
  PERFORM tests.eq(setting('loan_interest_rate'), 0.07,
    'and the new value is live immediately');

  -- The bypass is scoped to the caller, not switched on globally.
  PERFORM tests.as_user(v_a1);
  PERFORM tests.eq(required_approvals()::numeric, 2, 'an ordinary admin still needs two');
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_over);
  PERFORM tests.eq(required_approvals()::numeric, 1, 'the overseer needs one');
  PERFORM tests.as_owner();
END $$;

-- ============================================================================
-- B. The overseer's own money, in a group where they are the only admin.
--
--    036 made an admin's self-recorded payment a permanent two-signature matter
--    AND refused it outright below two admins. Both gates have to give way, or
--    the overseer is the one member whose payment cannot be recorded at all.
-- ============================================================================
DO $$
DECLARE
  v_over uuid;
  v_sub  uuid;
  v_pool numeric;
BEGIN
  v_over := tests.make_overseer('OvrB Overseer');

  -- The file is one transaction, so section A's admins are still here. Stand
  -- them down: this block is specifically about a group with a single admin.
  UPDATE profiles SET is_active = false WHERE role = 'admin' AND id <> v_over;

  v_pool := tests.pool();

  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM profiles WHERE role = 'admin' AND is_active = true),
    1, 'the overseer is the only admin in this block');

  PERFORM tests.as_user(v_over);
  v_sub := record_payment(v_over, 'savings_deposit', NULL, 40000, NULL);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM payment_submissions WHERE id = v_sub), 'approved',
    'the overseer records their own deposit and it settles at once');
  PERFORM tests.eq(tests.pool(), v_pool + 40000, 'the money is in the pool');
  PERFORM tests.assert_balanced('the overseer records their own deposit');

  -- The same act by an ordinary sole admin is still refused.
  UPDATE profiles SET is_superadmin = false WHERE id = v_over;
  PERFORM tests.as_user(v_over);
  PERFORM tests.raises(
    format($q$ SELECT record_payment(%L, 'savings_deposit', NULL, 40000, NULL) $q$, v_over),
    'a non-overseer sole admin still cannot record their own payment');
  PERFORM tests.as_owner();
END $$;

-- ============================================================================
-- C. The audit log still names the overseer.
--
--    The bypass removes the countersignature, not the record. An action leaving
--    no trace would be a different feature from the one that was asked for.
-- ============================================================================
DO $$
DECLARE
  v_over uuid;
  v_n    int;
BEGIN
  v_over := tests.make_overseer('OvrC Overseer');

  SELECT count(*) INTO v_n FROM audit_log WHERE actor_id = v_over;
  PERFORM tests.eq(v_n::numeric, 0, 'no history yet');

  PERFORM tests.as_user(v_over);
  PERFORM request_setting_change('penalty_rate', 0.10, 'Overseer sets the penalty');
  PERFORM tests.as_owner();

  SELECT count(*) INTO v_n FROM audit_log WHERE actor_id = v_over;
  PERFORM tests.eq((v_n > 0)::int::numeric, 1,
    'a unilateral overseer action is still written to the audit log');
END $$;

-- ============================================================================
-- D. The office cannot be seized, and cannot be stripped, from inside the app.
-- ============================================================================
DO $$
DECLARE
  v_over uuid;
  v_a1   uuid;
BEGIN
  v_over := tests.make_overseer('OvrD Overseer');
  v_a1   := tests.make_admin('OvrD Admin One');

  -- (a) escalation: the RLS UPDATE policy lets an admin write any profile column.
  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(
    format($q$ UPDATE profiles SET is_superadmin = true WHERE id = %L $q$, v_a1),
    'an admin cannot make themselves the overseer');
  PERFORM tests.raises(
    format($q$ UPDATE profiles SET is_superadmin = false WHERE id = %L $q$, v_over),
    'an admin cannot strip the overseer either');

  -- (b) removal by the ordinary governed route.
  PERFORM tests.raises(
    format($q$ UPDATE profiles SET role = 'member' WHERE id = %L $q$, v_over),
    'the overseer cannot be demoted');
  PERFORM tests.raises(
    format($q$ UPDATE profiles SET is_active = false WHERE id = %L $q$, v_over),
    'the overseer cannot be deactivated');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT role FROM profiles WHERE id = v_over), 'admin',
    'the overseer is still an admin');
  PERFORM tests.eq((SELECT is_superadmin::int::numeric FROM profiles WHERE id = v_over), 1,
    'and still holds the office');

  -- (c) the service role is the recovery path: clear the flag, then demote.
  UPDATE profiles SET is_superadmin = false WHERE id = v_over;
  UPDATE profiles SET role = 'member' WHERE id = v_over;
  PERFORM tests.eq((SELECT role FROM profiles WHERE id = v_over), 'member',
    'once the flag is cleared from the service role, the profile is ordinary again');
END $$;

-- ============================================================================
-- E. There is exactly one overseer.
-- ============================================================================
DO $$
DECLARE
  v_over uuid;
  v_a1   uuid;
BEGIN
  v_over := tests.make_overseer('OvrE Overseer');
  v_a1   := tests.make_admin('OvrE Admin One');

  PERFORM tests.raises(
    format($q$ UPDATE profiles SET is_superadmin = true WHERE id = %L $q$, v_a1),
    'a second overseer is refused even from the service role');
END $$;

-- ============================================================================
-- F. What the overseer is still bound by.
--
--    The lending caps are group_settings rows, not admin confirmations, so 041
--    leaves them standing. This is the documented boundary of the bypass — and
--    the second half shows it is not a limit in practice, because the overseer
--    now moves the setting alone and then proceeds.
-- ============================================================================
DO $$
DECLARE
  v_over uuid;
  v_m    uuid;
  v_loan uuid;
BEGIN
  v_over := tests.make_overseer('OvrF Overseer');
  v_m    := tests.make_member('OvrF Member');

  -- 100,000 contributed, so at the standing 5x multiplier the cap is 500,000.
  PERFORM tests.give_savings(v_over, 5000000);
  PERFORM tests.give_savings(v_m,     100000);

  PERFORM tests.as_user(v_over);
  PERFORM request_setting_change('pool_loan_fraction', 1.0, 'Overseer');
  v_loan := file_loan(v_m, 900000);
  PERFORM tests.raises(
    format($q$ SELECT approve_loan(%L, 'test://proof') $q$, v_loan),
    'the contribution multiplier still binds the overseer');
  PERFORM tests.as_owner();

  -- But the overseer lifts it alone, in one call, and it takes effect at once.
  PERFORM tests.as_user(v_over);
  PERFORM request_setting_change('contribution_multiplier', 20, 'Overseer');
  PERFORM approve_loan(v_loan, 'test://proof');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan), 'active',
    'having changed the cap alone, the overseer then approves the loan alone');
  PERFORM tests.assert_balanced('the overseer disburses a loan single-handed');
END $$;

-- ============================================================================
-- G. The loan-free-admin mandate is exempted for the overseer only.
-- ============================================================================
DO $$
DECLARE
  v_over uuid;
  v_a1   uuid;
  v_l1   uuid;
  v_l2   uuid;
BEGIN
  v_over := tests.make_overseer('OvrG Overseer');
  v_a1   := tests.make_admin('OvrG Admin One');

  PERFORM tests.give_savings(v_over, 5000000);
  PERFORM tests.give_savings(v_a1,   5000000);

  PERFORM tests.as_user(v_over);
  PERFORM request_setting_change('pool_loan_fraction', 0.99, 'Overseer');

  -- The other admin takes a loan first, leaving the overseer the only loan-free one.
  v_l1 := file_loan(v_a1, 100000);
  PERFORM approve_loan(v_l1, 'test://proof');

  -- 035 would refuse this: approving it leaves no loan-free admin.
  v_l2 := file_loan(v_over, 100000);
  PERFORM approve_loan(v_l2, 'test://proof');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_l2), 'active',
    'the overseer is exempt from the loan-free-admin mandate');
  PERFORM tests.assert_balanced('both admins hold loans');
END $$;
