-- 10_admin_mandate.test.sql — the lockdown from migration 034.
--
-- Every assertion in the first half FAILED before 034: each one is a live
-- privilege escalation a plain member could perform from the browser with the anon
-- key, because the schema shipped ten SECURITY DEFINER functions with no in-body
-- authorization check and no REVOKE, so they kept Postgres' default EXECUTE TO
-- PUBLIC. This file is the regression net for that whole class of bug — if a future
-- migration adds an `execute_*` and forgets its REVOKE, add it here.
--
-- The second half asserts the transparency that was deliberately KEPT. A lockdown
-- that also broke the member directory or the group accounts would be a different
-- product, so both directions are pinned.

DO $$
DECLARE
  v_admin  uuid;
  v_admin2 uuid;
  v_member uuid;
  v_other  uuid;
  v_fee    uuid;
  v_loan   uuid;
  v_req    uuid;
  v_change uuid;
BEGIN
  v_admin  := tests.make_admin('Mandate Admin');
  v_admin2 := tests.make_admin('Mandate Admin Two');
  v_member := tests.make_member('Mandate Member');
  v_other  := tests.make_member('Mandate Other');

  -- ================================================================
  -- 1. The execute_* family is unreachable from the client.
  --
  --    Each of these is the tail end of a 2-of-N flow. Reaching it directly is
  --    reaching past every signature the flow exists to collect.
  -- ================================================================

  -- A pending role change, created legitimately by one admin. Before 034 its id was
  -- admin-only to READ, but the function did not care who called it — and the three
  -- flows below leaked their ids to members outright.
  PERFORM tests.as_user(v_admin);
  v_req := request_role_change(v_member, 'promote', 'Test');
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_member);
  PERFORM tests.raises(format($q$ SELECT execute_role_change(%L) $q$, v_req),
    'a member cannot promote themselves to admin');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT role FROM profiles WHERE id = v_member), 'member',
    'the member is still a member');

  -- A setting change: fee amount, interest rate, penalty rate, loan multiplier.
  -- setting_changes was readable by every signed-in user, so before 034 a member
  -- could list a pending id and apply it themselves.
  PERFORM tests.as_user(v_admin);
  v_change := request_setting_change('monthly_fee_amount', 1, 'Test');
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_member);
  PERFORM tests.raises(format($q$ SELECT execute_setting_change(%L) $q$, v_change),
    'a member cannot rewrite the group rates');
  PERFORM tests.as_owner();

  PERFORM tests.eq(setting('monthly_fee_amount'), 10000,
    'the monthly fee is unchanged');

  -- The rest of the family. No pending row is needed: the REVOKE means permission
  -- is refused before the body runs, which is exactly the property under test.
  PERFORM tests.as_user(v_member);
  PERFORM tests.raises($q$ SELECT execute_savings_edit(gen_random_uuid()) $q$,
    'a member cannot apply a savings adjustment');
  PERFORM tests.raises($q$ SELECT execute_pool_edit(gen_random_uuid()) $q$,
    'a member cannot apply a pool adjustment');
  PERFORM tests.raises($q$ SELECT execute_member_deletion(gen_random_uuid()) $q$,
    'a member cannot delete a member');
  PERFORM tests.raises($q$ SELECT execute_loan_action(gen_random_uuid()) $q$,
    'a member cannot write off a loan');
  PERFORM tests.raises($q$ SELECT execute_cycle_close(gen_random_uuid()) $q$,
    'a member cannot close a cycle');
  PERFORM tests.raises($q$ SELECT execute_social_grant(gen_random_uuid()) $q$,
    'a member cannot pay out a social grant');
  PERFORM tests.as_owner();

  -- ================================================================
  -- 2. The messaging channel. Metered spend, and a text that arrives looking
  --    like it came from the group.
  -- ================================================================

  PERFORM tests.as_user(v_member);
  PERFORM tests.raises(
    format($q$ SELECT enqueue_delivery(%L, 'sms', 'x', NULL, 'y') $q$, v_other),
    'a member cannot send an SMS to another member');
  PERFORM tests.raises($q$ SELECT send_due_reminders() $q$,
    'a member cannot trigger a group-wide reminder sweep');
  PERFORM tests.as_owner();

  -- ================================================================
  -- 3. Members file nothing. This is the mandate itself.
  -- ================================================================

  v_fee := tests.give_fee(v_member, date_trunc('month', today_eat())::date);

  -- Control: the identical statement succeeds as the owner, so when it fails as a
  -- member below it is the dropped policy talking, not a bad column list.
  INSERT INTO payment_submissions
    (member_id, submission_type, related_id, amount_claimed, proof_url)
  VALUES (v_member, 'monthly_fee', v_fee, 10000, 'control.jpg');
  DELETE FROM payment_submissions WHERE proof_url = 'control.jpg';

  PERFORM tests.as_user(v_member);
  PERFORM tests.raises(format($q$
    INSERT INTO payment_submissions
      (member_id, submission_type, related_id, amount_claimed, proof_url)
    VALUES (%L, 'monthly_fee', %L, 10000, 'p.jpg') $q$, v_member, v_fee),
    'a member cannot file a payment');

  -- Columns are exactly the ones `loans` has: an INSERT that fails on a typo'd
  -- column would pass this assertion while proving nothing about RLS.
  PERFORM tests.raises(format($q$
    INSERT INTO loans (member_id, principal, status)
    VALUES (%L, 50000, 'pending') $q$, v_member),
    'a member cannot file a loan request');
  PERFORM tests.as_owner();

  -- And the same INSERT succeeds as the owner, which is what proves the failure
  -- above was the policy talking and not a malformed statement.
  INSERT INTO loans (member_id, principal, status) VALUES (v_member, 50000, 'pending');
  DELETE FROM loans WHERE member_id = v_member AND status = 'pending';

  -- The cross-member block that the old policy allowed: a member could file a
  -- pending submission against SOMEBODY ELSE's fee id (the policy bound member_id
  -- but never related_id) and freeze their real payment behind "already under
  -- review". Gone with the policy.
  PERFORM tests.as_user(v_other);
  PERFORM tests.raises(format($q$
    INSERT INTO payment_submissions
      (member_id, submission_type, related_id, amount_claimed, proof_url)
    VALUES (%L, 'monthly_fee', %L, 1, 'p.jpg') $q$, v_other, v_fee),
    'a member cannot file against another member''s fee');
  PERFORM tests.as_owner();

  -- ================================================================
  -- 4. The role column is out of reach of the browser entirely, so the
  --    2-of-N role vote cannot be walked around with a direct UPDATE.
  --    An admin is tested here, not a member: the admin was the one who could.
  -- ================================================================

  PERFORM tests.as_user(v_admin);
  PERFORM tests.raises(format($q$
    UPDATE profiles SET role = 'admin' WHERE id = %L $q$, v_member),
    'an admin cannot promote directly, bypassing the vote');
  PERFORM tests.raises(format($q$
    UPDATE profiles SET is_active = false WHERE id = %L $q$, v_member),
    'an admin cannot deactivate directly');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT role FROM profiles WHERE id = v_member), 'member',
    'still a member after the direct-update attempt');

  -- The voted path still works end to end — the lockdown must not have broken
  -- the flow it protects.
  PERFORM tests.as_user(v_admin2);
  PERFORM approve_role_change(v_req);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT role FROM profiles WHERE id = v_member), 'admin',
    'two signatures still promote');

  -- ================================================================
  -- 5. A deactivated admin is not an admin.
  --
  --    is_admin() checked role only. required_approvals() and execute_role_change
  --    both checked is_active, so the schema disagreed with itself about who
  --    counted — and the permissive reading was the one guarding every RPC.
  -- ================================================================

  UPDATE profiles SET is_active = false WHERE id = v_member;   -- now an admin

  PERFORM tests.as_user(v_member);
  PERFORM tests.eq(is_admin()::text, 'false',
    'a deactivated admin does not pass is_admin()');
  PERFORM tests.eq(is_active_member()::text, 'false',
    'a deactivated profile is not an active member');
  PERFORM tests.as_owner();

  UPDATE profiles SET is_active = true, role = 'member' WHERE id = v_member;

  -- ================================================================
  -- 6. Transparency that was deliberately KEPT.
  --
  --    Losing the ability to file a transaction is not the same as losing sight
  --    of the group. If a later change narrows any of these, it should have to
  --    delete a test that says so on purpose.
  -- ================================================================

  PERFORM tests.as_user(v_member);
  PERFORM group_member_directory();          -- every member's savings + loan
  PERFORM group_income_statement(
    (today_eat() - 365)::date, today_eat());  -- the group's books
  PERFORM group_balance_sheet(today_eat());
  PERFORM member_ledger(v_member, (today_eat() - 365)::date, today_eat());
  PERFORM tests.as_owner();

  PERFORM tests.eq(
    (SELECT count(*) FROM group_settings WHERE key = 'monthly_fee_amount')::numeric,
    1, 'an active member still reads the group settings');

  -- But one member's operational detail is not another member's business.
  PERFORM tests.as_user(v_member);
  PERFORM tests.raises(format($q$ SELECT member_ledger(%L, %L, %L) $q$,
      v_other, (today_eat() - 365)::date, today_eat()),
    'a member cannot read another member''s ledger');
  PERFORM tests.as_owner();

  RAISE NOTICE '10_admin_mandate: ok';
END;
$$;
