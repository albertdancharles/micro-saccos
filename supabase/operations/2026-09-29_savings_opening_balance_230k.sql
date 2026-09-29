-- 2026-09-29_savings_opening_balance_230k.sql
--
-- NOT A MIGRATION. Run once, by hand, against the live project. See ./README.md.
--
-- WHAT. Records 230,000.00 TZS of savings for every ACTIVE member — one
-- savings_adjustments row each, already approved. At 7 active members that is
-- 1,610,000.00 TZS of new member capital.
--
-- WHY A SAVINGS ADJUSTMENT AND NOT A DEPOSIT SUBMISSION. A payment_submission is a
-- claim someone made and an admin reviewed; there is a photo, a date, a reviewer.
-- None of that exists here — this is a balance the group is asserting, not a payment
-- anybody submitted through the app. savings_adjustments is the table for exactly
-- that (013), it is what `getApprovedSavings` sums, and it is on BOTH sides of the
-- reconciliation identity (027: member_capital and v_group_pool), so the books stay
-- balanced with no further entry.
--
-- WHY status='approved' DIRECTLY AND NOT request_savings_edit(). The RPC is the
-- in-app 2-of-N governance path: it needs an auth.uid(), it refuses to target another
-- admin, and it allows only one pending request per member. None of those fit a
-- hand-run operation carrying a decision the group already made together. This is the
-- same stance ./2026-08-25_opening_balance_reset.sql took when it wrote group_settings
-- directly. requested_by is left NULL because no admin requested it in the app.
--
-- WHAT THIS CHANGES BESIDES THE SAVINGS NUMBER — read before running:
--
--   1. THE POOL GROWS BY THE SAME 1,610,000. v_group_pool counts approved
--      adjustments as cash, so the app will treat that money as liquid and
--      loanable. If the cash is NOT actually in the group's account, this makes the
--      app lie about what it can lend. Only run this if the money is real.
--
--   2. EVERY LOAN CEILING RISES. The ceiling is min(5x contribution, 25% of pool)
--      evaluated at request time (031, and group_settings). 230,000 each takes the
--      5x arm to 1,150,000 per member, and the 25% arm up with the pool.
--
--   3. SHARE-OUT WEIGHTING IS DATED TODAY. applied_at feeds
--      v_member_capital_events, which feeds member_cycle_basis (023). Money landing
--      on 2026-09-29 earns member-months only from 2026-09-29 — it does NOT get
--      backdated credit for the earlier part of the cycle. If the group means this
--      capital to have been in from the cycle's start, set v_applied_at below to
--      that date instead.
--
--   4. EVERY MEMBER IS NOTIFIED. The insert into notifications mirrors what
--      execute_savings_edit() sends, so a member sees the change in the app rather
--      than finding their balance silently different. The fan-out trigger (026) then
--      queues an SMS for anyone with sms_opt_in and a phone number. The drain job is
--      not scheduled, so nothing leaves today — but those rows will sit in
--      notification_deliveries ready to send if it ever is. Comment out section 3
--      if the group would rather be told at the meeting.
--
-- INACTIVE MEMBERS ARE EXCLUDED. `is_active = false` is an exited member; crediting
-- savings to someone who has left would create a claim the group does not owe.
-- Admins and the overseer ARE included: 001 says all of them are contributing
-- members and `role` only distinguishes permission.

begin;

do $$
declare
  -- The three things to check before running.
  v_delta      numeric(12,2) := 230000.00;
  v_reason     text := 'Opening savings balance recorded for every active member by group decision, 2026-09-29.';
  v_applied_at timestamptz   := now();

  v_members int;
  v_total   numeric(12,2);
  v_roster  text;
begin
  -- Idempotency. The reason text is the marker: re-running this file would double
  -- every member's balance, and nothing about a second identical row would look
  -- wrong to anyone reading the table later.
  if exists (select 1 from savings_adjustments
              where reason = v_reason and status = 'approved') then
    raise exception
      'ABORTED: % member(s) already carry an adjustment with this exact reason. '
      'This file has been run. Delete those rows first if you truly mean to redo it.',
      (select count(*) from savings_adjustments
        where reason = v_reason and status = 'approved');
  end if;

  select count(*), string_agg(full_name, ', ' order by full_name)
    into v_members, v_roster
    from profiles where is_active = true;

  if v_members = 0 then
    raise exception 'ABORTED: no active members. Nothing to credit.';
  end if;

  v_total := v_delta * v_members;

  -- 1. The money.
  insert into savings_adjustments
    (target_member_id, requested_by, delta, reason, status, applied_at)
  select p.id, null, v_delta, v_reason, 'approved', v_applied_at
    from profiles p
   where p.is_active = true;

  -- 2. The trail. One row for one decision, listing who it touched — the same shape
  --    as the 2026-08-25 reset's audit entry, and enough to reconstruct this later
  --    from the audit log alone.
  insert into audit_log (actor_id, action, target_type, target_id, details)
  values (null, 'savings_opening_balance_load', 'system', null,
          jsonb_build_object(
            'delta_per_member', v_delta,
            'members_credited', v_members,
            'total_credited',   v_total,
            'applied_at',       v_applied_at,
            'reason',           v_reason,
            'roster',           v_roster,
            'note', 'Hand-run operations file, not an in-app savings edit. '
                    'No 2-of-N approval: the group decided this together.'));

  -- 3. Telling them. Comment this block out to stay silent — see note 4 in the header.
  insert into notifications (recipient_id, kind, title, body, data)
  select p.id, 'savings_edited',
         'Your savings was adjusted',
         'An adjustment of ' || v_delta || ' TZS was applied. Reason: ' || v_reason,
         jsonb_build_object('delta', v_delta, 'source', 'opening_balance_load')
    from profiles p
   where p.is_active = true;

  raise notice 'Credited % TZS to % member(s). Total %. Members: %',
    v_delta, v_members, v_total, v_roster;
end $$;

commit;

-- --------------------------------------------------------------------------
-- Verify. Every member should show at least 230000.00, and `balanced` must be
-- true — if it is false, the identity broke and something above is wrong.
-- --------------------------------------------------------------------------

select p.full_name,
       p.role,
       coalesce(sum(sa.delta), 0) as adjustments_tzs
  from profiles p
  left join savings_adjustments sa
         on sa.target_member_id = p.id and sa.status = 'approved'
 where p.is_active = true
 group by p.id, p.full_name, p.role
 order by p.full_name;

select 'members credited' as check,
       (select count(*)::text from savings_adjustments
         where status = 'approved' and delta = 230000.00) as value
union all select 'pool',      (select pool_tzs::text        from v_pool_reconciliation)
union all select 'capital',   (select member_capital_tzs::text from v_pool_reconciliation)
union all select 'difference',(select difference_tzs::text  from v_pool_reconciliation)
union all select 'balanced',  (select balanced::text        from v_pool_reconciliation);
