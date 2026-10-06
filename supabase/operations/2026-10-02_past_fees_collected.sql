-- 2026-10-02_past_fees_collected.sql
--
-- NOT A MIGRATION. Run once, by hand, against the live project. See ./README.md.
--
-- WHAT. Settles EVERY unpaid monthly fee for EVERY active member in every period
-- BEFORE the current month, and takes the same money back off that member's
-- opening-balance adjustment so nobody's savings total moves. It is the September
-- file's operation widened to all earlier periods and all members at once.
--
-- WHY. The group's position, stated 2026-10-02: every monthly fee up to and
-- including September was handed over at the meeting it was due at, and that money
-- is already inside the 230,000 each member was credited on 2026-09-29. There is no
-- unpaid fee. But rows for the earlier periods still sit `pending` in the database,
-- so every member's dashboard adds them into AMOUNT DUE -- money they have already
-- paid, counted against them a second time.
--
-- WHY "MARK COLLECTED" AND NOT "VOID". The word used for this was void, and the
-- schema has no such thing: monthly_fees.status is pending / partial / paid and
-- nothing else (021), so the only two operations available are to mark the row paid
-- or to delete it. Deleting says the fee never existed. What happened is that it was
-- collected, which is what this file records -- and it keeps the month in the fee
-- history members scroll back through, so a member can still see that they paid.
-- This is the same reasoning ./2026-09-29_september_fee_collected.sql set out.
--
-- WHY THE OFFSET IS NOT OPTIONAL HERE. Savings and the pool both read
-- monthly_fees.amount_paid as cash (v_group_pool, 021; getApprovedSavings). Marking
-- these rows paid on its own would therefore COUNT THE SAME MONEY TWICE: every
-- member would gain the full amount of their arrears and the pool would gain the
-- group total, for money that is already sitting in the 230,000. So each member's
-- opening adjustment comes down by exactly what their fee rows go up by:
--
--     before:  adjustment 230,000 + fees      0  = 230,000
--     after:   adjustment 210,000 + fees 20,000  = 230,000   (a member owing Aug + Sep)
--
-- Same total, same pool, books still balanced -- the composition is simply true now.
--
-- IF THE ARREARS ARE REALLY NEW MONEY ON TOP of the 230,000 -- i.e. the group means
-- each member to end up richer once this is recorded -- set v_offset_opening := false.
-- Only do that if the cash is actually in the account on top of what the pool already
-- claims. It is not what the group said on 2026-10-02.
--
-- WHAT IT DELIBERATELY DOES NOT TOUCH.
--
--   * THE CURRENT MONTH. October's fee is not an arrear; it falls due at the 31
--     October meeting and is not yet payable. It stays pending, which is what the
--     dashboard should show. The cutoff is computed from today_eat() at run time,
--     so this stays true whenever the file is run.
--   * ROWS WITH MONEY ALREADY ON THEM. A part-paid row has a real
--     payment_submissions trail and an audit story this file would overwrite; the
--     run aborts and names them rather than guessing. Settle those in the admin
--     screen.
--   * FEES ALREADY MARKED PAID. A member who settled August in the app on
--     2026-09-12 paid real money ON TOP of their opening balance. Taking it off now
--     would rob them. Those rows are already 'paid' and so never enter the target
--     set -- but it is also why the verification at the foot of this file prints
--     each member's composition: those members legitimately hold MORE than 230,000,
--     and that is not something this file should quietly flatten.
--   * INACTIVE MEMBERS. An exited member was never credited an opening balance
--     (the 2026-09-29 file skipped them), so there is nothing to offset against.
--     Their rows are counted, reported, and left alone.
--
-- PENALTIES DISAPPEAR WITH THE ARREAR, AND THAT IS CORRECT. v_fee_status computes
-- penalty_months as 0 the moment status = 'paid', so no fine survives this. Nothing
-- is actually waived: penalty_rate has been 0 since the 2026-08-25 reset and is
-- snapshotted per row, so these rows carry no penalty to begin with. The run reports
-- the figure it cleared either way.
--
-- SAFE TO RUN TWICE. The second run finds no target rows and aborts before writing.
-- It is the FIRST run that needs care, which is why v_confirm starts false: the file
-- refuses on a first pass and prints the exact roster, period by period, that it
-- would settle. Read that against the group's own record, then set it true.

begin;

do $$
declare
  -- ---- Check these four before running. --------------------------------------
  --
  -- false = print what would happen and change nothing. Flip to true to write.
  v_confirm         boolean := false;
  -- false = the arrears are NEW money on top of the 230,000. Read the header.
  v_offset_opening  boolean := true;
  -- Everything strictly before this period is an arrear. Current month is excluded.
  v_cutoff_period   date    := date_trunc('month', today_eat())::date;
  -- The marker the 2026-09-29 opening-balance file wrote. Must match it byte for
  -- byte or the offset will not find the row to reduce.
  v_opening_reason  text := 'Opening savings balance recorded for every active member by group decision, 2026-09-29.';
  -- ----------------------------------------------------------------------------

  -- Off. Every row inserted into `notifications` fires on_notification_fan_out
  -- (migration 026), which queues a real, billed SMS per member -- to announce a
  -- savings total that has not moved. The group already knows it paid; the
  -- dashboard simply has to stop contradicting them. Set true only to send.
  v_notify          boolean := false;

  v_fee_rows      int;
  v_fee_total     numeric(12,2);
  v_members       int;
  v_penalty_clear numeric(12,2);
  v_skipped       int;
  v_offset_rows   int := 0;
  v_offset_total  numeric(12,2) := 0;
  v_preview       text;
  v_roster        text;
begin
  -- The target set, fixed once so every later step aims at exactly these rows.
  -- Active members only; see the header on inactive ones.
  create temp table _settling on commit drop as
  select mf.id, mf.member_id, mf.period, mf.amount, mf.amount_paid
    from monthly_fees mf
    join profiles p on p.id = mf.member_id and p.is_active = true
   where mf.period < v_cutoff_period
     and mf.status <> 'paid';

  select count(*), coalesce(sum(amount - amount_paid), 0), count(distinct member_id)
    into v_fee_rows, v_fee_total, v_members
    from _settling;

  -- Idempotency FIRST, before any complaint about preconditions: a second run must
  -- be met with "this has already happened", never with an instruction that would be
  -- harmful to follow twice.
  if v_fee_rows = 0 then
    raise exception
      'ABORTED: no unpaid fee rows before %. Every earlier fee is already settled -- '
      'this file has run, or there was nothing to do.', v_cutoff_period;
  end if;

  -- Rows with money already banked against them. These have a submissions trail and
  -- a partial-payment history; settling them here would overwrite it, and offsetting
  -- the full amount would take back money the member really did hand over on top.
  if exists (select 1 from _settling where amount_paid > 0) then
    raise exception
      'ABORTED: % row(s) are part-paid through the app. Settle those in the admin '
      'screen, then re-run. Rows: %',
      (select count(*) from _settling where amount_paid > 0),
      (select string_agg(p.full_name || ' ' || to_char(s.period, 'Mon YYYY')
                         || ' (' || s.amount_paid || ' of ' || s.amount || ')', '; '
                         order by p.full_name)
         from _settling s join profiles p on p.id = s.member_id
        where s.amount_paid > 0);
  end if;

  if v_offset_opening then
    -- One opening-balance row per member, or the UPDATE below would subtract the
    -- member's arrears once per matching row and silently overshoot.
    if exists (
      select 1 from savings_adjustments
       where status = 'approved' and reason = v_opening_reason
       group by target_member_id having count(*) > 1
    ) then
      raise exception
        'ABORTED: some member carries more than one approved opening-balance row with '
        'the marker reason. The offset would be applied to each. Investigate first.';
    end if;

    -- Every member being settled must have an opening balance for the money to come
    -- off. Without one they would silently gain their whole arrears.
    if exists (
      select 1 from _settling s
       where not exists (select 1 from savings_adjustments sa
                          where sa.target_member_id = s.member_id
                            and sa.status = 'approved'
                            and sa.reason = v_opening_reason)
    ) then
      raise exception
        'ABORTED: % member(s) being settled have no opening-balance adjustment to '
        'offset against, so they would gain their arrears as new money: %',
        (select count(distinct s.member_id) from _settling s
          where not exists (select 1 from savings_adjustments sa
                             where sa.target_member_id = s.member_id
                               and sa.status = 'approved'
                               and sa.reason = v_opening_reason)),
        (select string_agg(distinct p.full_name, ', ' order by p.full_name)
           from _settling s join profiles p on p.id = s.member_id
          where not exists (select 1 from savings_adjustments sa
                             where sa.target_member_id = s.member_id
                               and sa.status = 'approved'
                               and sa.reason = v_opening_reason));
    end if;

    -- savings_adjustments carries CHECK (delta <> 0), so an offset that lands a
    -- member exactly on zero fails the constraint and takes the whole transaction
    -- with it -- and one that goes negative would be a member whose arrears exceed
    -- the opening balance they are supposed to be inside. Both mean the premise is
    -- wrong for that member, so say which, rather than let a constraint say it.
    if exists (
      select 1
        from (select member_id, sum(amount - amount_paid) as owed
                from _settling group by member_id) o
        join savings_adjustments sa
          on sa.target_member_id = o.member_id
         and sa.status = 'approved' and sa.reason = v_opening_reason
       where sa.delta - o.owed <= 0
    ) then
      raise exception
        'ABORTED: for % member(s) the arrears are not smaller than the opening '
        'balance they are meant to be inside, so the offset would zero or reverse '
        'it: %',
        (select count(*) from (select member_id, sum(amount - amount_paid) as owed
                                 from _settling group by member_id) o
           join savings_adjustments sa on sa.target_member_id = o.member_id
            and sa.status = 'approved' and sa.reason = v_opening_reason
          where sa.delta - o.owed <= 0),
        (select string_agg(p.full_name || ' (owes ' || o.owed || ', opening '
                           || sa.delta || ')', '; ' order by p.full_name)
           from (select member_id, sum(amount - amount_paid) as owed
                   from _settling group by member_id) o
           join savings_adjustments sa on sa.target_member_id = o.member_id
            and sa.status = 'approved' and sa.reason = v_opening_reason
           join profiles p on p.id = o.member_id
          where sa.delta - o.owed <= 0);
    end if;
  end if;

  -- What the penalty columns say today, measured before the update rather than
  -- written in as a literal, so the audit row records what was actually cleared.
  select coalesce(sum(fm.penalty_due), 0) into v_penalty_clear
    from v_fee_status_money fm join _settling s on s.id = fm.id;

  -- Rows left behind because their member has exited. Reported, never settled.
  select count(*) into v_skipped
    from monthly_fees mf join profiles p on p.id = mf.member_id
   where mf.period < v_cutoff_period and mf.status <> 'paid' and p.is_active = false;

  -- The preview. Built on every run, confirmed or not: on a refusal it is the whole
  -- point, and on a real run it is the record of what was done.
  select string_agg(line, chr(10) order by line) into v_preview
    from (select '    ' || rpad(p.full_name, 22) || ' '
                 || to_char(s.period, 'Mon YYYY') || '  '
                 || to_char(s.amount - s.amount_paid, 'FM999,999,990') || ' TZS' as line
            from _settling s join profiles p on p.id = s.member_id) q;

  select string_agg(distinct p.full_name, ', ' order by p.full_name) into v_roster
    from _settling s join profiles p on p.id = s.member_id;

  -- The roster goes INSIDE the refusal, not into a raise notice. A NOTICE does not
  -- survive every way this file gets run — `supabase db query --linked -f` returns
  -- the exception and drops the notices — and a preview whose roster is invisible is
  -- no preview at all. Same reason the re-anchoring file prints its batch this way.
  if not v_confirm then
    raise exception
      E'PREVIEW ONLY — NOTHING WAS WRITTEN.\n\n'
      '% fee row(s) across % member(s), % TZS, in periods before %:\n\n%\n\n'
      'Each one is marked collected, dated the meeting of its own month, and the same '
      'total comes off that member''s opening balance — so every savings total and the '
      'pool stay exactly where they are. % row(s) belonging to inactive members are '
      'left alone, and the current month (%) is not touched: it falls due at its own '
      'meeting and is not an arrear.\n\n'
      'CHECK THAT ROSTER AGAINST THE GROUP''S OWN RECORD. If every one of those months '
      'really was handed over, set\n\n    v_confirm := true;\n\n'
      'in the block above and run the file again.',
      v_fee_rows, v_members, v_fee_total, v_cutoff_period, v_preview,
      v_skipped, to_char(v_cutoff_period, 'Mon YYYY');
  end if;

  -- 1. The fees are collected -- each dated the meeting of its OWN month, which is
  --    when the money was handed over, not today. The last Saturday of that month:
  --    step back from its last day to the most recent Saturday (EXTRACT(DOW) is 0
  --    Sunday, 6 Saturday, so (dow + 1) % 7 is the distance back). Spelled out
  --    rather than calling meeting_day() so this file does not depend on migration
  --    043 having been applied -- it runs against the schema as it stands.
  --
  --    penalty_collected stays 0: the group fined nobody, and these rows carry a
  --    penalty_rate of 0 anyway.
  update monthly_fees mf
     set amount_paid = mf.amount,
         status      = 'paid',
         paid_at     = (m.meeting + time '12:00') at time zone 'Africa/Dar_es_Salaam'
    from (select s.id,
                 (eom.d - ((extract(dow from eom.d)::int + 1) % 7))::date as meeting
            from _settling s,
                 lateral (select (s.period + interval '1 month'
                                            - interval '1 day')::date as d) eom) m
   where mf.id = m.id;

  -- 2. The same money comes off the opening balance, member by member and summed
  --    across their periods -- NOT a flat amount, so a member owing one month and a
  --    member owing two are each left exactly whole.
  --
  --    The reason text is deliberately LEFT ALONE: it is the marker the 2026-09-29
  --    files and this one all use to recognise the row, and rewriting it would make
  --    the opening file's idempotency guard miss and credit everybody a second
  --    230,000. It names no amount, so it stays accurate as the delta falls. The
  --    reduction is recorded in the audit row below.
  if v_offset_opening then
    with owed as (
      select member_id, sum(amount - amount_paid) as total
        from _settling group by member_id
    ), offsets as (
      update savings_adjustments sa
         set delta = sa.delta - owed.total
        from owed
       where sa.target_member_id = owed.member_id
         and sa.status = 'approved'
         and sa.reason = v_opening_reason
      returning sa.target_member_id, owed.total
    )
    select count(*), coalesce(sum(total), 0) into v_offset_rows, v_offset_total
      from offsets;

    -- Every member settled must have found an opening balance to come off. If not,
    -- somebody is richer than the group thinks and the whole transaction is wrong.
    if v_offset_rows <> v_members then
      raise exception
        'ABORTED: settled % member(s) but only % had an opening balance to offset. '
        'The difference would be silently gained.', v_members, v_offset_rows;
    end if;
  end if;

  insert into audit_log (actor_id, action, target_type, target_id, details)
  values (null, 'past_fees_recorded_collected', 'system', null,
          jsonb_build_object(
            'cutoff_period',    v_cutoff_period,
            'fee_rows_settled', v_fee_rows,
            'fee_total',        v_fee_total,
            'members',          v_members,
            'penalty_cleared',  v_penalty_clear,
            'opening_offset',   v_offset_opening,
            'offset_rows',      v_offset_rows,
            'offset_total',     v_offset_total,
            'inactive_skipped', v_skipped,
            'members_notified', v_notify,
            'roster',           v_roster,
            'note', case when v_offset_opening
                      then 'Composition only: savings totals and the pool are unchanged. '
                           'Every fee before the current month was already inside the '
                           '230,000 opening balance. Group decision, 2026-10-02.'
                      else 'NEW money: every member gains their arrears and the pool '
                           'grows by the total.' end));

  -- Gated off by default -- see the declaration. If sent, it says only that the
  -- record now matches what they did; their number has not moved.
  if v_notify then
    insert into notifications (recipient_id, kind, title, body, data)
    select s.member_id, 'fee_recorded',
           'Your earlier contributions are recorded',
           'Your monthly contributions up to '
           || to_char(v_cutoff_period - 1, 'Mon YYYY')
           || ', collected at the meetings, are now recorded against those months. '
           || case when v_offset_opening then 'Your savings total is unchanged.' else '' end,
           jsonb_build_object('rows', count(*), 'total', sum(s.amount - s.amount_paid))
      from _settling s
     group by s.member_id;
  end if;

  raise notice
    'Settled % fee row(s) (% TZS) for % member(s); % penalty cleared. '
    'Opening balances reduced on % row(s) (% TZS). % inactive row(s) left alone.',
    v_fee_rows, v_fee_total, v_members, v_penalty_clear,
    v_offset_rows, v_offset_total, v_skipped;
end $$;

commit;

-- --------------------------------------------------------------------------
-- Verify.
-- --------------------------------------------------------------------------

-- 1. Nothing before the current month is unpaid any more. Expect no rows.
select period, computed_status, count(*)
  from v_fee_status
 where period < date_trunc('month', today_eat())::date
   and computed_status <> 'paid'
 group by period, computed_status
 order by period;

-- 2. Every member's composition. With the offset on, `savings_total` must read the
--    same as it did before this ran. A member who paid a fee through the app with
--    real money on top of their opening balance will show MORE than 230,000 -- that
--    is correct and is not this file's to flatten, but it is worth looking at.
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

-- 3. The books. `balanced` must be true and the pool must read what it did before.
select 'pool'       as check, (select pool_tzs::text           from v_pool_reconciliation) as value
union all select 'capital',   (select member_capital_tzs::text from v_pool_reconciliation)
union all select 'difference',(select difference_tzs::text     from v_pool_reconciliation)
union all select 'balanced',  (select balanced::text           from v_pool_reconciliation);
