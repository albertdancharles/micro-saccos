-- 2026-10-01_loans_reanchored_to_the_26_sep_meeting.sql
--
-- NOT A MIGRATION. Run once, by hand, against the live project. See ./README.md.
--
-- WHAT. The loans the group agreed and handed out at the meeting of Saturday
-- 2026-09-26 were recorded in the app afterwards, through the ordinary
-- file_loan / approve_loan flow — by hand, member by member, which is the right
-- way to do it and leaves a real two-admin approval trail. But approve_loan
-- stamps the approval with `now()` and counts the repayment schedule from it, so
-- the books came out describing a different loan from the one the group made:
--
--     what happened                 what the app recorded
--     ------------------------------------------------------------------
--     money left Sat 2026-09-26     disbursed on the day of the recording
--     1st repayment  2026-10-31     1st repayment 2026-11-28
--     2nd repayment  2026-11-28     2nd repayment 2026-12-26
--     3rd repayment  2026-12-26     3rd repayment 2027-01-30
--
-- The October meeting was skipped. Every borrower would arrive on 31 October with
-- a month's interest and find nothing asked of them; the group would wait until
-- 28 November for the first shilling back on nearly four million of lending; and
-- a three-month loan would close in January.
--
-- Migration 048 fixes the rule for every future approval — the schedule is
-- counted from the meeting the money was handed over at, not from the day an
-- admin typed it in. THIS FILE restates the loans already recorded under the old
-- rule. Apply 048 before or after; neither needs the other, and this file
-- computes its dates itself.
--
-- WHAT IT CHANGES, per loan:
--
--   * requested_at, approved_at, disbursed_at -> 2026-09-26 12:00 EAT. The group
--     asked, agreed and paid out in the room, all on that Saturday.
--   * installment n's due_date -> the n-th meeting after 26 September, i.e.
--     2026-10-31, 2026-11-28, 2026-12-26 — via meeting_day() (043), so the
--     arithmetic is the app's own and a different term length still works.
--
-- WHAT IT DOES NOT CHANGE. Who borrowed, how much, the interest (3 x 5% of
-- principal, unchanged per installment and in total), outstanding principal, the
-- pool, total assets, any payment, any savings balance. NO MONEY MOVES — this is
-- a correction to dates and nothing else, and v_pool_reconciliation reads exactly
-- the same before and after.
--
-- It also leaves `loan_approvals` alone. Those rows carry the moment each admin
-- actually signed in the app, which is a fact about the recording and worth
-- keeping; what moves is the loan's own account of when the group agreed and the
-- cash changed hands.
--
-- ------------------------------------------------------------------------
-- THIS MOVES DUE DATES EARLIER. Read before setting the flag.
--
-- The backfill 043 sketched could only ever move a date later, which is why it
-- was safe to call harmless. This one moves each installment back by one meeting,
-- and that is stricter on the member: the first repayment is asked for on 31
-- October rather than 28 November, and the loan closes in December rather than
-- January. It is what the group agreed in the room and what every borrower was
-- told at the meeting — but a date nobody can be held to retroactively is a
-- different thing, so:
--
--   * the file REFUSES to run if any new due date is today or earlier. Nothing
--     here may create an overdue installment, or a penalty, for a meeting that
--     has already come and gone. Run it before 31 October 2026.
--   * it REFUSES if any installment it would move has been paid, part-paid,
--     cancelled, or has a payment submission waiting on it. Money already
--     allocated against a due date is not something a date correction walks over.
--     That refusal prints the loan id, so one awkward loan can be set aside in
--     `v_skip` and the rest of the batch still corrected.
--
-- NOTIFICATIONS. None. `on_loan_status_change` is an AFTER UPDATE **OF status**
-- trigger (009) and no status changes here, so nothing is queued and no SMS is
-- billed (026). The borrowers do need to hear that the first repayment is 31
-- October — tell them at the meeting, or send one deliberate message; a
-- correction file does not get to spend the group's airtime.
-- ------------------------------------------------------------------------
--
-- IDEMPOTENT. A second run finds every date already correct and stops with a
-- notice, writing nothing. Loans recorded by
-- ./2026-09-29_meeting_loans_issued.sql, had that file been used instead of the
-- app, are already anchored to the meeting and are passed over the same way.

begin;

-- Every active loan the group handed out at the September meeting: recorded on or
-- after that Saturday and before the next meeting, which is the window in which
-- "a loan recorded in the app" can only mean "the September batch, written up
-- late". A loan disbursed at the October meeting itself falls outside it and is
-- left alone.
create temp table op_reanchor (
  loan_id     uuid primary key,
  member_name text not null,
  principal   numeric(12,2) not null,
  recorded_on date,
  old_dates   text,
  new_dates   text,
  moves       boolean not null default false
) on commit drop;

do $$
declare
  -- The things to check before running.
  v_meeting   date        := date '2026-09-26';                     -- the meeting
  v_issued_at timestamptz := timestamptz '2026-09-26 12:00:00+03';  -- and its clock time
  v_confirm   boolean     := false;  -- see THIS MOVES DUE DATES EARLIER

  -- Loans to leave exactly as they are. Normally empty; the refusals below print
  -- the id of anything that cannot be moved safely, to paste in here.
  v_skip      uuid[]      := '{}';

  v_next_meeting date;
  v_count        int;
  v_moving       int;
  v_restamping   int;
  v_total        numeric(14,2);
  v_problem      text;
  v_preview      text;
  v_schedule     text;
  v_earliest     date;
  r              record;
begin
  v_next_meeting := meeting_day((v_meeting + interval '1 month')::date);

  -- -------------------------------------------------------------- the batch
  insert into op_reanchor (loan_id, member_name, principal, recorded_on)
  select l.id,
         p.full_name,
         l.principal,
         (l.disbursed_at at time zone 'Africa/Dar_es_Salaam')::date
    from loans l
    join profiles p on p.id = l.member_id
   where l.status = 'active'
     and l.disbursed_at is not null
     and (l.disbursed_at at time zone 'Africa/Dar_es_Salaam')::date >= v_meeting
     and (l.disbursed_at at time zone 'Africa/Dar_es_Salaam')::date <  v_next_meeting
     and not (l.id = any (v_skip));

  select count(*), coalesce(sum(principal), 0) into v_count, v_total from op_reanchor;

  if v_count = 0 then
    select string_agg('  ' || p.full_name || '  ' || l.principal
                      || '  disbursed ' || coalesce(l.disbursed_at::date::text, '(never)'),
                      E'\n' order by l.disbursed_at)
      into v_problem
      from loans l join profiles p on p.id = l.member_id
     where l.status = 'active';
    raise exception E'ABORTED: no active loan was recorded between % and %, so there is nothing here to re-anchor.\n\nThe active loans are:\n%\n\nIf the meeting date at the top of this file is wrong, fix it. If the loans are not in the app at all yet, record them first — or use ./2026-09-29_meeting_loans_issued.sql, which writes the schedule from the meeting in the first place.',
      v_meeting, v_next_meeting, coalesce(v_problem, '  (none at all)');
  end if;

  -- ------------------------------------------- what moves, and what it moves to
  -- Per loan: the schedule as it stands, and the schedule the meeting gives.
  -- `moves` is false for a loan already anchored correctly, which is what makes a
  -- second run a no-op.
  for r in select * from op_reanchor loop
    update op_reanchor o
       set old_dates = s.old_dates,
           new_dates = s.new_dates,
           moves     = s.old_dates is distinct from s.new_dates
      from (
        select string_agg(to_char(i.due_date, 'DD Mon YYYY'),
                          ' / ' order by i.installment_number) as old_dates,
               string_agg(to_char(meeting_day((v_meeting + (i.installment_number || ' month')::interval)::date),
                                  'DD Mon YYYY'),
                          ' / ' order by i.installment_number) as new_dates
          from loan_installments i
         where i.loan_id = r.loan_id
      ) s
     where o.loan_id = r.loan_id;
  end loop;

  select count(*) into v_moving from op_reanchor where moves;

  -- A loan can need the timestamps moved without its dates moving (recorded on
  -- the meeting day itself, say), so both are counted before deciding there is
  -- nothing to do.
  select count(*) into v_restamping
    from loans l join op_reanchor o on o.loan_id = l.id
   where l.disbursed_at <> v_issued_at
      or l.approved_at is distinct from v_issued_at;

  if v_moving = 0 and v_restamping = 0 then
    raise notice E'Nothing to change: all % loans are already anchored to the % meeting. No rows were written.',
      v_count, v_meeting;
    return;
  end if;

  -- -------------------------------------------------------- nothing paid yet
  -- A due date that money has already been allocated against is not a date this
  -- file gets to move.
  select string_agg('  ' || o.member_name || ' installment ' || i.installment_number
                    || ' (' || i.status
                    || case when i.principal_paid > 0 then ', principal paid ' || i.principal_paid else '' end
                    || case when i.penalty_collected > 0 then ', penalty collected ' || i.penalty_collected else '' end
                    || ')  loan ' || o.loan_id,
                    E'\n' order by o.member_name, i.installment_number)
    into v_problem
    from op_reanchor o
    join loan_installments i on i.loan_id = o.loan_id
   where o.moves
     and (i.status <> 'pending' or i.principal_paid > 0 or i.penalty_collected > 0);

  if v_problem is not null then
    raise exception E'ABORTED — NOTHING WAS WRITTEN. These installments are already settled or cancelled, so their dates are part of a payment record:\n%\n\nSettle those with the group by hand. To move the REST of the batch, paste the loan ids above into v_skip at the top of this file and run it again.',
      v_problem;
  end if;

  select string_agg('  ' || o.member_name || ' installment ' || i.installment_number
                    || ': a ' || ps.status || ' submission for ' || ps.amount_claimed
                    || '  loan ' || o.loan_id,
                    E'\n' order by o.member_name, i.installment_number)
    into v_problem
    from op_reanchor o
    join loan_installments i on i.loan_id = o.loan_id
    join payment_submissions ps
      on ps.related_id = i.id
     and ps.submission_type = 'loan_installment'
     and ps.status in ('pending', 'approved')
   where o.moves;

  if v_problem is not null then
    raise exception E'ABORTED — NOTHING WAS WRITTEN. A member has already submitted against one of these installments:\n%\n\nReview or reject those submissions first: the allocation (011) depends on the due date and on the penalty that follows from it. Or put those loan ids in v_skip and move the rest.',
      v_problem;
  end if;

  -- ------------------------------------------- no date may land in the past
  select min(meeting_day((v_meeting + (i.installment_number || ' month')::interval)::date))
    into v_earliest
    from op_reanchor o join loan_installments i on i.loan_id = o.loan_id
   where o.moves;

  if v_earliest is not null and v_earliest <= today_eat() then
    raise exception E'ABORTED — NOTHING WAS WRITTEN. The earliest new due date is % and today is %. Moving an installment into the past makes it overdue the moment this commits, and starts charging a penalty for a meeting nobody can go back to. This correction had to be made before that meeting; what the member owes now is a question for the group.',
      v_earliest, today_eat();
  end if;

  -- -------------------------------------------------------------- the reading
  select string_agg('  ' || rpad(o.member_name, 20)
                    || lpad(to_char(o.principal, 'FM999,999,999'), 10)
                    || '   recorded ' || coalesce(o.recorded_on::text, '?')
                    || case when o.moves then '' else '   (schedule already anchored)' end,
                    E'\n' order by o.member_name)
    into v_preview from op_reanchor o;

  -- The schedules themselves, grouped: loans agreed at one meeting share one set
  -- of dates, and printing it once per loan would bury the change.
  select string_agg(line, E'\n') into v_schedule
    from (
      select '  ' || count(*) || ' loan(s):  ' || old_dates || '   ->   ' || new_dates as line
        from op_reanchor
       where moves
       group by old_dates, new_dates
       order by count(*) desc
    ) g;

  if not v_confirm then
    raise exception E'ABORTED — NOTHING WAS WRITTEN.\n\nThese % active loans were recorded between % and %, totalling % TZS:\n\n%\n\n% of them carry a schedule counted from the day they were typed in. It becomes a schedule counted from the meeting:\n\n%\n\nAll % are also restated as requested, approved and disbursed at % — the meeting itself.\n\nCHECK THAT AGAINST THE MINUTES FIRST, and read "THIS MOVES DUE DATES EARLIER" at the top of this file: every one of these dates moves BACK one meeting. If that is what the group agreed, set\n\n    v_confirm := true;\n\nin the block above and run the file again.',
      v_count, v_meeting, v_next_meeting, v_total, v_preview,
      v_moving, coalesce(v_schedule, '  (no schedule moves — only the timestamps)'),
      v_count,
      to_char(v_issued_at at time zone 'Africa/Dar_es_Salaam', 'YYYY-MM-DD HH24:MI') || ' EAT';
  end if;

  -- ------------------------------------------------------------------- write
  for r in select * from op_reanchor order by member_name loop
    -- The loan's own account of when the group acted. requested_at moves too:
    -- left where it was, the books would show a loan approved before it was asked
    -- for. `least` so a request genuinely filed earlier keeps its own date.
    update loans
       set requested_at = least(requested_at, v_issued_at),
           approved_at  = v_issued_at,
           disbursed_at = v_issued_at
     where id = r.loan_id;

    update loan_installments i
       set due_date = meeting_day((v_meeting + (i.installment_number || ' month')::interval)::date)
     where i.loan_id = r.loan_id
       and i.due_date <> meeting_day((v_meeting + (i.installment_number || ' month')::interval)::date);

    insert into audit_log (actor_id, action, target_type, target_id, details)
    values (null, 'loan_schedule_reanchored', 'loan', r.loan_id,
            jsonb_build_object(
              'member',        r.member_name,
              'principal',     r.principal,
              'recorded_on',   r.recorded_on,
              'issued_at',     v_issued_at,
              'meeting',       v_meeting,
              'due_dates_was', r.old_dates,
              'due_dates_now', r.new_dates,
              'note', 'Hand-run operations file. The loan was agreed and disbursed '
                      'at the meeting of 2026-09-26 and recorded in the app days '
                      'later; approve_loan counted the schedule from the recording '
                      'and skipped the October meeting. Dates only — no money '
                      'moved. See operations/'
                      '2026-10-01_loans_reanchored_to_the_26_sep_meeting.sql and '
                      'migration 048.'));
  end loop;

  raise notice E'Re-anchored % of % loans to the % meeting (% TZS).\n%\n\nSchedules:\n%',
    v_moving, v_count, v_meeting, v_total, v_preview,
    coalesce(v_schedule, '  (timestamps only)');
end $$;

commit;

-- --------------------------------------------------------------------------
-- Verify. Every active loan disbursed 2026-09-26, three meeting dates starting
-- 2026-10-31, nothing overdue, and the pool untouched — a date correction cannot
-- move money.
-- --------------------------------------------------------------------------

select p.full_name,
       l.principal,
       l.outstanding_principal,
       l.disbursed_at,
       (select string_agg(i.due_date::text, ' / ' order by i.installment_number)
          from loan_installments i where i.loan_id = l.id) as due_dates
  from loans l join profiles p on p.id = l.member_id
 where l.status = 'active'
 order by p.full_name;

select i.due_date,
       count(*)             as installments,
       sum(i.interest_due)  as interest_due,
       sum(i.principal_due) as principal_due,
       sum(i.total_due)     as total_due
  from loan_installments i
  join loans l on l.id = i.loan_id
 where l.status = 'active'
 group by i.due_date
 order by i.due_date;

select 'overdue now'  as check, (select count(*)::text from v_installment_status i
                                  join loans l on l.id = i.loan_id
                                 where l.status = 'active'
                                   and i.computed_status = 'overdue') as value
union all select 'pool',         (select pool_tzs::text         from v_pool_reconciliation)
union all select 'outstanding',  (select outstanding_tzs::text  from v_pool_reconciliation)
union all select 'total assets', (select total_assets_tzs::text from v_pool_reconciliation)
union all select 'balanced',     (select balanced::text         from v_pool_reconciliation);
