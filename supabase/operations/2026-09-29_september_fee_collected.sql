-- 2026-09-29_september_fee_collected.sql
--
-- NOT A MIGRATION. Run once, by hand, against the live project. See ./README.md.
-- Run it AFTER ./2026-09-29_savings_opening_balance_230k.sql, never before.
--
-- WHAT. Records the September 2026 monthly fee as collected for every member who
-- has a September row, dated the meeting it was collected at (Sat 2026-09-26),
-- and takes the same amount back off that member's opening-balance adjustment so
-- nobody's savings total moves.
--
-- WHY THE OFFSET — THE WHOLE POINT OF THIS FILE.
--
-- The group collected September's 10,000 at the meeting on 2026-09-26. That money
-- is already inside the 230,000 each member was credited three days later: 230,000
-- is what they have saved TODAY, September included. But the app was never told
-- which part of it was the fee, so the September rows still sit unpaid and every
-- member's dashboard shows AMOUNT DUE 10,000 for money they have already handed
-- over.
--
-- Marking those rows paid on its own would fix the card and break the total:
-- getApprovedSavings() sums monthly_fees.amount_paid AND savings_adjustments, so
-- the same 10,000 would be counted twice and every member would jump to 240,000,
-- with the pool following to 3,360,000. So the opening adjustment comes down by
-- exactly what the fee row goes up by:
--
--     before:  adjustment 230,000 + fee      0  = 230,000
--     after:   adjustment 220,000 + fee 10,000  = 230,000
--
-- Same total, same pool, books still balanced — but now the composition is true,
-- and Profile's contributions breakdown can say "220,000 saved, 10,000 in fees"
-- instead of attributing the lot to an opening balance.
--
-- IF THE 230,000 DID *NOT* INCLUDE SEPTEMBER — i.e. the group means each member to
-- hold 240,000 once September is recorded — set v_offset_opening := false below.
-- That records the fee as new money: every member gains 10,000 and the pool gains
-- 10,000 x the number of members. Only do that if the cash is really in the
-- account on top of the 3,220,000.
--
-- WHY NOT DELETE THE ROWS INSTEAD. Deleting says the fee never existed; marking it
-- paid says it was collected, which is what happened. It also keeps September in
-- the fee history members can scroll back through, and — unlike a delete — it
-- survives ensure_current_fees(), which would re-raise a deleted September row on
-- the very next dashboard load because September is still the current month. That
-- is exactly how the August rows came back after the 2026-08-25 reset.

begin;

do $$
declare
  -- Check these three before running.
  v_period          date    := date '2026-09-01';
  v_collected_at    timestamptz := timestamptz '2026-09-26 12:00:00+03';  -- the meeting
  v_offset_opening  boolean := true;   -- false = the 230,000 did NOT include September

  -- Off. Every row inserted into `notifications` fires on_notification_fan_out
  -- (migration 026), which queues an SMS for each member with sms_opt_in and a
  -- phone number — real messages, billed per member, to announce a savings total
  -- that has not moved. The group was told at the meeting; the dashboard simply
  -- has to stop contradicting them. Set true only if you want the SMS sent.
  v_notify          boolean := false;

  v_opening_reason  text := 'Opening savings balance recorded for every active member by group decision, 2026-09-29.';

  -- Whose September row THIS run settles. Anyone who paid through the app before
  -- it ran is not in here, and must not be: their 10,000 was real money on top of
  -- the opening balance, so taking it back off would rob them.
  v_member_ids   uuid[];

  v_fees_marked  int;
  v_fee_total    numeric(12,2);
  v_offset_rows  int := 0;
  v_offset_total numeric(12,2) := 0;
  v_roster       text;
begin
  -- Idempotency FIRST. A second run would take another 10,000 off every opening
  -- balance, and this has to be the message the operator sees — checking for the
  -- opening balances ahead of it would greet a re-run with "run the opening-balance
  -- file first", which is the one instruction that must not be followed twice.
  if not exists (
    select 1 from monthly_fees where period = v_period and status <> 'paid'
  ) then
    raise exception
      'ABORTED: every September 2026 fee row is already marked paid. This file has run.';
  end if;

  -- Only then: refuse if the opening-balance file has not run. The offset would
  -- have nothing to come off, and running these two out of order is the one way to
  -- get a wrong total that still reconciles.
  if v_offset_opening and not exists (
    select 1 from savings_adjustments where reason = v_opening_reason and status = 'approved'
  ) then
    raise exception
      'ABORTED: no opening-balance adjustments found. Run '
      '2026-09-29_savings_opening_balance_230k.sql first, or set v_offset_opening := false.';
  end if;

  -- Refuse if anything has been part-paid through the app since. Those rows have a
  -- real payment_submissions trail behind them and an audit story this file would
  -- overwrite; settle them the normal way instead.
  if exists (
    select 1 from monthly_fees
     where period = v_period and amount_paid > 0 and status <> 'paid'
  ) then
    raise exception
      'ABORTED: % September row(s) are part-paid through the app. Settle those in '
      'the admin screen rather than here.',
      (select count(*) from monthly_fees
        where period = v_period and amount_paid > 0 and status <> 'paid');
  end if;

  -- 1. The fee is collected. penalty_collected stays 0: penalty_rate has been 0
  --    since the opening reset, and the group charged nobody a fine in September.
  --
  --    The roster is taken BEFORE the update so the offset below can be aimed at
  --    exactly these members. A member who settled September in the app already
  --    has status = 'paid' and so never enters this list.
  select array_agg(member_id) into v_member_ids
    from monthly_fees
   where period = v_period and status <> 'paid';

  with marked as (
    update monthly_fees
       set amount_paid = amount,
           status      = 'paid',
           paid_at     = v_collected_at
     where period = v_period
       and member_id = any(v_member_ids)
    returning member_id, amount
  )
  select count(*), coalesce(sum(amount), 0),
         string_agg(p.full_name, ', ' order by p.full_name)
    into v_fees_marked, v_fee_total, v_roster
    from marked m join profiles p on p.id = m.member_id;

  -- 2. The same money comes off the opening balance, member by member — NOT a flat
  --    10,000, so a member whose fee amount differed is still exactly whole.
  if v_offset_opening then
    -- The reason text is deliberately LEFT ALONE. It is the marker both this file
    -- and the opening-balance file use to recognise their own work, and rewriting
    -- it would make the opening file's idempotency guard miss on a later run and
    -- credit everybody a second 230,000. It also stays accurate: it names no
    -- amount, so it describes a 220,000 delta exactly as well as a 230,000 one.
    -- The reduction is recorded in the audit_log row below.
    --
    -- Restricted to v_member_ids. Without that the offset would reach every
    -- member holding a September row — including one who had already paid
    -- through the app — and take 10,000 off an opening balance that never
    -- contained it. The count check below would catch it and abort, which is
    -- safe but leaves the file unrunnable the moment one member settles early:
    -- the rest of the group then stays stuck showing AMOUNT DUE 10,000.
    with offsets as (
      update savings_adjustments sa
         set delta = sa.delta - mf.amount
        from monthly_fees mf
       where mf.member_id = sa.target_member_id
         and mf.period    = v_period
         and mf.member_id = any(v_member_ids)
         and sa.status    = 'approved'
         and sa.reason    = v_opening_reason
      returning sa.target_member_id, mf.amount
    )
    select count(*), coalesce(sum(amount), 0) into v_offset_rows, v_offset_total
      from offsets;

    -- Every fee marked paid must have found an opening balance to come off. If it
    -- did not, some member is now 10,000 richer than the group thinks and the
    -- whole transaction is wrong.
    if v_offset_rows <> v_fees_marked then
      raise exception
        'ABORTED: marked % fee(s) paid but only % had an opening balance to offset. '
        'Those members would silently gain the difference.',
        v_fees_marked, v_offset_rows;
    end if;
  end if;

  insert into audit_log (actor_id, action, target_type, target_id, details)
  values (null, 'september_fee_recorded_collected', 'system', null,
          jsonb_build_object(
            'period',            v_period,
            'collected_at',      v_collected_at,
            'fees_marked_paid',  v_fees_marked,
            'fee_total',         v_fee_total,
            'opening_offset',    v_offset_opening,
            'offset_rows',       v_offset_rows,
            'offset_total',      v_offset_total,
            'members_notified',  v_notify,
            'roster',            v_roster,
            'note', case when v_offset_opening
                      then 'Composition only: savings totals and the pool are unchanged. '
                           'The fee was already inside the 230,000 opening balance.'
                      else 'NEW money: every member gains the fee amount and the pool '
                           'grows by the total.' end));

  -- Tell them, but only that the record now matches what they did — their number
  -- has not moved, and a notification implying otherwise would cause more worry
  -- than silence. Gated on v_notify because this insert is not free: see the
  -- declaration above.
  if v_notify then
    insert into notifications (recipient_id, kind, title, body, data)
    select mf.member_id, 'fee_recorded',
           'September fee recorded',
           case when v_offset_opening
             then 'Your September contribution of ' || mf.amount ||
                  ' TZS, collected at the meeting on 26 September, is now recorded ' ||
                  'against the month. Your savings total is unchanged.'
             else 'Your September contribution of ' || mf.amount ||
                  ' TZS, collected at the meeting on 26 September, is now recorded.'
           end,
           jsonb_build_object('period', v_period, 'amount', mf.amount)
      from monthly_fees mf
     where mf.period = v_period and mf.member_id = any(v_member_ids);
  end if;

  raise notice 'September: % fee(s) marked paid (% TZS). Opening balances reduced on % row(s) (% TZS). Members: %',
    v_fees_marked, v_fee_total, v_offset_rows, v_offset_total, v_roster;
end $$;

commit;

-- --------------------------------------------------------------------------
-- Verify. With the offset on, every member should still read 230,000 total,
-- split 220,000 opening + 10,000 fee, and `balanced` must be true.
-- --------------------------------------------------------------------------

select p.full_name,
       coalesce((select sum(sa.delta) from savings_adjustments sa
                  where sa.target_member_id = p.id and sa.status = 'approved'), 0) as adjustments,
       coalesce((select sum(mf.amount_paid) from monthly_fees mf
                  where mf.member_id = p.id), 0)                                   as fees_paid,
       coalesce((select sum(sa.delta) from savings_adjustments sa
                  where sa.target_member_id = p.id and sa.status = 'approved'), 0)
     + coalesce((select sum(mf.amount_paid) from monthly_fees mf
                  where mf.member_id = p.id), 0)                                   as savings_total
  from profiles p
 where p.is_active = true
 order by p.full_name;

-- September must be fully settled, and nothing should show as due for it.
select period, computed_status, count(*)
  from v_fee_status
 where period = date '2026-09-01'
 group by period, computed_status;

select 'pool'       as check, (select pool_tzs::text         from v_pool_reconciliation) as value
union all select 'capital',   (select member_capital_tzs::text from v_pool_reconciliation)
union all select 'difference',(select difference_tzs::text   from v_pool_reconciliation)
union all select 'balanced',  (select balanced::text         from v_pool_reconciliation);
