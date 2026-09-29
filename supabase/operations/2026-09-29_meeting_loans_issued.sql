-- 2026-09-29_meeting_loans_issued.sql
--
-- NOT A MIGRATION. Run once, by hand, against the live project. See ./README.md.
-- Run it AFTER ./2026-09-29_pool_profit_3932700.sql. Without that money in the
-- pool these loans overdraw it by 312,700 and this file will refuse.
--
-- WHAT. Records the thirteen loans the group agreed and handed out at the
-- meeting on Saturday 2026-09-26, as active, disbursed loans with their
-- repayment schedules — the state approve_loan() would have left behind.
--
--     Veroda Makunja     200,000       Amani Ngoko        100,000
--     Raheli Mosha       200,000       Peter Okama        250,000
--     Pius Mushi         400,000       Silivana Kambanga  100,000
--     Kelvin Sinde       350,000       Yuda Ntandu        400,000
--     Albert Charles     532,700       Massoud Massoud    400,000
--     Eva                200,000       Jackson Onyango    400,000
--     Deus Owano         400,000       -------------------------
--                                      total            3,932,700
--
-- Every one of these is pinned to a named member — by phone number where the
-- number is known, which is all of them but Eva. Nuru Mwakisyala is the one
-- active member who did not borrow.
--
-- WHAT IT DOES TO THE BOOKS. Nothing is created or destroyed: 3,932,700 moves
-- from the liquid pool to outstanding principal.
--
--     pool          3,932,700 -> 0
--     outstanding           0 -> 3,932,700
--     total assets  3,932,700 (unchanged, and v_pool_reconciliation stays balanced)
--
-- THE POOL ENDS AT EXACTLY ZERO. The thirteen loans come to 3,932,700, which is
-- the pool to the shilling. That is the group's call and this file records it
-- rather than arguing with it, but it is worth saying plainly what an empty pool
-- means until the first repayments land on 2026-10-31:
--
--   * no further loan can be disbursed. The CEILING is unaffected — since 045
--     it is a share of group assets, which lending does not change, so it stays
--     at 983,175 — but approve_loan also requires the pool to hold the cash, and
--     it holds none;
--   * no withdrawal or member exit can be paid out;
--   * close_cycle() would refuse a full share-out for want of cash.
--
-- The social fund's 290,000 is untouched and still available for a grant: it is
-- a separate pot and was never part of the pool (030).
--
-- THE SCHEDULE. Each loan gets `default_loan_months` installments (3) at
-- `loan_interest_rate` (5% a month, interest-only until the last one, which
-- carries the whole principal) — identical arithmetic to approve_loan, with the
-- dates anchored to the MEETING the loans were issued at rather than to the day
-- this file is run:
--
--     inst 1  due 2026-10-31   interest only
--     inst 2  due 2026-11-28   interest only
--     inst 3  due 2026-12-26   interest + the whole principal
--
-- Those are the last Saturdays of October, November and December — the meeting
-- days, via meeting_day() from 043, which is the point of that migration.
-- Interest is round(principal x 0.05) per installment, so the group is owed
-- 196,635 a month and 589,905 over the three months.
--
-- ------------------------------------------------------------------------
-- THE RULES THIS RECORDING BYPASSES. Read before setting the flag.
--
-- This file inserts the loan rows directly instead of calling file_loan() and
-- approve_loan() twice each, because those RPCs need an auth.uid() per signature
-- and there is no in-app approval trail to reconstruct — the group approved
-- these in the room. But that also means none of approve_loan's ceilings fire.
-- The file evaluates every one of them itself and REFUSES TO RUN until you set
-- `v_acknowledge_rule_breaches := true`, printing exactly which loans break
-- what. Nothing is hidden and nothing is written until you say so.
--
-- Of the four checks below, two are clean and two are not: the loans sit inside
-- the group's lending ceiling and inside its cash, but they breach the
-- contribution rule as approve_loan computes it, and they leave no admin
-- loan-free.
--
--   1. 25% OF GROUP ASSETS (`pool_loan_fraction`, re-based by migration 045).
--      NO LOAN HERE BREAKS THIS, and it is worth saying why, because under the
--      old rule three of them did. The cap used to be a share of the liquid
--      pool, which falls with every loan, so it shrank as the meeting went on
--      and refused the last three borrowers for no reason but their place in
--      the queue. Measured against total assets — pool plus what is out on loan
--      — it holds still at 983,175 all meeting, and the largest loan here is
--      Albert's 532,700.
--
--      This file computes the cap from v_group_assets directly, so its report is
--      the same whether or not 045 has reached the database yet. Apply 045 all
--      the same: without it approve_loan still measures against the pool, and
--      the very next loan the group files in the app would be refused against a
--      pool this recording leaves at zero.
--
--      The file also checks, loan by loan in `seq` order, that the pool could
--      actually cover each disbursement — 045 added that to approve_loan, since
--      a ceiling measured against assets no longer guarantees the cash. It can:
--      the thirteen come to exactly the pool, so every one of them is covered
--      at its turn and the pool lands on zero, never below.
--
--   2. 5x CONTRIBUTION (`contribution_multiplier`). approve_loan counts as
--      "contribution" only approved savings_deposit submissions plus PAID
--      MONTHLY FEES. It does NOT count savings_adjustments — and the 230,000
--      every member holds is entirely savings_adjustments, from the
--      opening-balance file. So by the app's arithmetic each member's
--      contribution is the 10,000 or 20,000 of fees they have paid, their cap is
--      50,000 or 100,000, and nearly every loan here breaches it. By the
--      arithmetic the group actually uses — 5 x 230,000 = 1,150,000 — not one of
--      them does. That is a discrepancy in approve_loan, not in the group's
--      decision, and it is worth fixing in a migration; this file only reports
--      it.
--
--   3. ONE ADMIN STAYS LOAN-FREE (034, exempting the overseer). Thirteen of
--      fourteen members borrowed. If the admins are among them, no admin is left
--      without a loan and the mandate is broken. The file reports the exact
--      position from the live roster, which is the only place that is knowable.
--
-- Whatever it finds is written into the audit_log row for every loan, so the
-- breach is part of the record rather than a thing that happened quietly.
-- ------------------------------------------------------------------------
--
-- ONE LOAN PER MEMBER. If any of these thirteen already has a pending or active
-- loan the file aborts. That is 036's rule, and it doubles as the idempotency
-- guard: after a successful run every one of them holds an active loan, so a
-- second run cannot get past it.
--
-- NOTIFICATIONS. Each borrower gets the ordinary 'loan_active' notification —
-- the one the app's own trigger sends — because the rows go in as 'pending' and
-- are then moved to 'active', exactly as an approval does. What is suppressed is
-- the on_new_loan trigger, which would otherwise tell every admin thirteen times
-- that a new loan has been REQUESTED. Nothing was requested; it was agreed and
-- paid out. That suppression is the first statement in the file and needs the
-- role that OWNS `loans` (`postgres` in the Supabase SQL editor). If it fails,
-- nothing at all has been written — either run as the owner, or delete the two
-- ALTER TABLE lines and clear the stray 'new_loan' rows afterwards with
--   delete from notifications where kind = 'new_loan' and created_at > <now>;
--
-- The SMS fan-out (026) will queue a delivery per borrower. The drain job is
-- still not scheduled, so nothing leaves today.

begin;

-- See NOTIFICATIONS above. Re-enabled at the foot of this file; if anything
-- below fails, the whole transaction rolls back and the trigger is never left
-- disabled.
alter table loans disable trigger on_new_loan;

-- WHO BORROWED WHAT.
--
-- Each row names ONE member, by phone number wherever the number is known.
-- Phone is `profiles.phone_number`, which is UNIQUE (001), so it identifies a
-- person exactly; a first name does not. Three of these would have gone wrong
-- on names alone — the group's register spells them Raheli, Silivana and
-- Massoud Massoud, none of which a match on 'Rahel' or 'Silvana' would find.
-- The numbers below are the ones the group was set up with (scripts/seed.mjs).
--
-- `full_name` is NOT how the row is matched when a phone is given; it is
-- checked AGAINST the profile the phone found. If a number has moved to a
-- different person since the group was set up, that mismatch stops the file
-- rather than quietly lending 400,000 in the wrong name.
--
-- Eva has no number here because she joined after the group was seeded and the
-- repository does not know it. Her row is matched on name, which works as long
-- as she is the only active Eva; if the file stops on her, put her full name or
-- her number in and run it again.
--
-- `seq` is the order the meeting took them in. It matters to ONE check: since
-- 045 the lending ceiling is the same figure for everybody in the room, but
-- whether the pool could cover each disbursement depends on what had already
-- been handed out, so that one is walked in this order.
create temp table op_meeting_loans (
  seq          int  primary key,
  full_name    text not null unique,
  phone_number text unique,
  principal    numeric(12,2) not null check (principal > 0),
  member_id    uuid,
  loan_id      uuid
) on commit drop;

insert into op_meeting_loans (seq, full_name, phone_number, principal) values
  ( 1, 'Veroda Makunja',    '+255679044511', 200000.00),
  ( 2, 'Raheli Mosha',      '+255757595443', 200000.00),
  ( 3, 'Pius Mushi',        '+255764174646', 400000.00),
  ( 4, 'Kelvin Sinde',      '+255753463567', 350000.00),
  ( 5, 'Albert Charles',    '+255655500410', 532700.00),
  ( 6, 'Eva',               null,            200000.00),
  ( 7, 'Deus Owano',        '+255737646188', 400000.00),
  ( 8, 'Amani Ngoko',       '+255717195783', 100000.00),
  ( 9, 'Peter Okama',       '+255621328108', 250000.00),
  (10, 'Silivana Kambanga', '+255756300222', 100000.00),
  (11, 'Yuda Ntandu',       '+255621115735', 400000.00),
  (12, 'Massoud Massoud',   '+255655036403', 400000.00),
  (13, 'Jackson Onyango',   '+255712154837', 400000.00);

-- Not borrowing, and that is the whole of the difference between 14 members and
-- 13 loans: Nuru Mwakisyala (+255716731151).

do $$
declare
  -- The two things to check before running.
  v_issued_at   timestamptz := timestamptz '2026-09-26 12:00:00+03';  -- the meeting
  v_acknowledge_rule_breaches boolean := false;  -- see THE THREE RULES

  v_fraction   numeric := setting('pool_loan_fraction');
  v_multiplier numeric := setting('contribution_multiplier');
  v_rate       numeric := setting('loan_interest_rate');
  v_months     int     := setting('default_loan_months')::int;
  v_penalty    numeric := setting('penalty_rate');

  v_total        numeric(14,2);
  v_count        int;
  v_pool         numeric(14,2);
  v_assets       numeric(14,2);
  v_running_pool numeric(14,2);
  v_cap_assets   numeric(14,2);
  v_contribution numeric(14,2);
  v_cap_member   numeric(14,2);
  v_interest     numeric(12,2);
  v_breaches     text := '';
  v_breach_list  text[] := '{}';
  v_problem      text;
  v_roster       text;
  v_assignment   text;
  v_admins       int;
  v_admin_loans  int;
  v_loan_id      uuid;
  r              record;
  v_n            int;
begin
  select count(*), sum(principal) into v_count, v_total from op_meeting_loans;

  -- ------------------------------------------------------- who each loan is for
  -- By phone number where there is one: phone_number is UNIQUE on profiles, so
  -- it names a person and a first name does not. Only the rows with no number
  -- fall back to the name, matched case-insensitively and accepting a leading
  -- word, so 'Eva' finds 'Eva Mtui' — but if it finds two Evas the file stops
  -- rather than guessing which one just borrowed 200,000.
  select string_agg(x.line, E'\n' order by x.seq) into v_problem
    from (
      select o.seq,
             '  ' || o.full_name
               || coalesce(' (' || o.phone_number || ')', ' (no number given)')
               || ' -> ' ||
             case when count(p.id) = 0 then 'no active member matches'
                  else count(p.id) || ' members match: ' ||
                       string_agg(p.full_name, ' / ' order by p.full_name) end as line
        from op_meeting_loans o
        left join profiles p
               on p.is_active = true
              and (case when o.phone_number is not null
                        then p.phone_number = o.phone_number
                        else lower(p.full_name) = lower(o.full_name)
                             or lower(p.full_name) like lower(o.full_name) || ' %'
                   end)
       group by o.seq, o.full_name, o.phone_number
      having count(p.id) <> 1
    ) x;

  if v_problem is not null then
    select string_agg('  ' || full_name || coalesce(' (' || phone_number || ')', ''),
                      E'\n' order by full_name) into v_roster
      from profiles where is_active = true;
    raise exception E'ABORTED: these rows do not resolve to one active member each.\n%\n\nThe active roster is:\n%\n\nFix the number or the name in the table above, then re-run.',
      v_problem, v_roster;
  end if;

  update op_meeting_loans o
     set member_id = p.id
    from profiles p
   where p.is_active = true
     and (case when o.phone_number is not null
               then p.phone_number = o.phone_number
               else lower(p.full_name) = lower(o.full_name)
                    or lower(p.full_name) like lower(o.full_name) || ' %'
          end);

  -- Two rows must not land on the same person.
  if (select count(distinct member_id) from op_meeting_loans) <> v_count then
    raise exception 'ABORTED: two rows resolve to the same member.';
  end if;

  -- A number that has moved to somebody else would sail through the match above
  -- and lend 400,000 in the wrong name. The name written beside the number has
  -- to agree with the profile the number found.
  select string_agg('  ' || o.full_name || ' (' || o.phone_number || ') is '
                    || p.full_name || ' in the register', E'\n' order by o.seq)
    into v_problem
    from op_meeting_loans o
    join profiles p on p.id = o.member_id
   where o.phone_number is not null
     and lower(p.full_name) <> lower(o.full_name);

  if v_problem is not null then
    raise exception E'ABORTED: a number belongs to someone other than the name beside it.\n%\n\nIf the member has simply changed how their name is spelled, update the table above to match the register. If the NUMBER has moved to a different person, find the right one before lending in their name.',
      v_problem;
  end if;

  -- --------------------------------------------------------------- one loan
  select string_agg('  ' || p.full_name || ' (' || l.status || ')', E'\n' order by p.full_name)
    into v_problem
    from loans l
    join op_meeting_loans o on o.member_id = l.member_id
    join profiles p on p.id = l.member_id
   where l.status in ('pending', 'active');

  if v_problem is not null then
    raise exception E'ABORTED: these members already have a loan in progress. If they are the loans below, THIS FILE HAS ALREADY RUN.\n%',
      v_problem;
  end if;

  -- ------------------------------------------------------------------- pool
  select pool_balance_tzs into v_pool from v_group_pool;

  if v_total > v_pool then
    raise exception
      'ABORTED: the thirteen loans total % but the pool holds only % — short by %. '
      'Run 2026-09-29_pool_profit_3932700.sql first.',
      v_total, v_pool, v_total - v_pool;
  end if;

  -- ------------------------------------------------------------- the reading
  -- Who is getting what, in the register's own names, so the operator can check
  -- the assignment against the minutes BEFORE anything is written. It is shown
  -- in the refusal below and again in the notice on a successful run.
  select string_agg('  ' || rpad(p.full_name, 20) ||
                    lpad(to_char(o.principal, 'FM999,999,999'), 10) ||
                    coalesce('  ' || p.phone_number, ''), E'\n' order by o.seq)
    into v_assignment
    from op_meeting_loans o join profiles p on p.id = o.member_id;

  -- --------------------------------------------------------- the three rules
  -- 045: the ceiling is a share of what the group is WORTH, and lending does not
  -- change that, so it is one figure for the whole meeting rather than one per
  -- loan. v_group_assets rather than the pool, so any loan already outstanding
  -- before this meeting counts toward it too.
  select total_assets_tzs into v_assets from v_group_assets;
  v_cap_assets   := floor(v_fraction * v_assets);
  v_running_pool := v_pool;

  for r in select o.*, p.full_name as member_name, p.role, p.is_superadmin
             from op_meeting_loans o join profiles p on p.id = o.member_id
            order by o.seq
  loop
    -- 1a. A quarter of the group, the same for everyone in the room.
    if r.principal > v_cap_assets then
      v_breach_list := v_breach_list || format(
        '  %s: %s exceeds %s%% of group assets (assets %s, max %s)',
        r.member_name, r.principal, round(v_fraction * 100), v_assets, v_cap_assets);
    end if;

    -- 1b. And the cash had to be there when it was handed over. Only this one
    --     depends on the order in `seq`.
    if r.principal > v_running_pool then
      v_breach_list := v_breach_list || format(
        '  %s: %s could not have been disbursed — the pool held only %s by that point in the meeting',
        r.member_name, r.principal, v_running_pool);
    end if;
    v_running_pool := v_running_pool - r.principal;

    -- 2. 5x contribution, using approve_loan's formula exactly — deposits and
    --    paid fees only, no savings_adjustments. See rule 2 in the header.
    select
        coalesce((select sum(amount_claimed) from payment_submissions
                   where member_id = r.member_id
                     and submission_type = 'savings_deposit'
                     and status = 'approved'), 0)
      + coalesce((select sum(amount) from monthly_fees
                   where member_id = r.member_id and status = 'paid'), 0)
      into v_contribution;

    v_cap_member := floor(v_multiplier * v_contribution);
    if r.principal > v_cap_member then
      v_breach_list := v_breach_list || format(
        '  %s: %s exceeds %sx contribution (contribution %s by approve_loan''s count, max %s)',
        r.member_name, r.principal, v_multiplier, v_contribution, v_cap_member);
    end if;
  end loop;

  -- 3. One admin must stay loan-free.
  select count(*) into v_admins
    from profiles where role = 'admin' and is_active = true and is_superadmin = false;

  select count(distinct m.id) into v_admin_loans
    from profiles m
   where m.role = 'admin' and m.is_active = true and m.is_superadmin = false
     and (exists (select 1 from loans l where l.member_id = m.id and l.status = 'active')
          or exists (select 1 from op_meeting_loans o where o.member_id = m.id));

  if v_admins > 0 and v_admin_loans >= v_admins then
    v_breach_list := v_breach_list || format(
      '  all %s admin(s) other than the overseer would hold an active loan — no admin left loan-free (034)',
      v_admins);
  end if;

  if array_length(v_breach_list, 1) > 0 then
    v_breaches := array_to_string(v_breach_list, E'\n');
    if not v_acknowledge_rule_breaches then
      raise exception E'ABORTED — NOTHING WAS WRITTEN.\n\nThis is who would be recorded, and for how much:\n\n%\n\nCheck that against the minutes first. Recording it breaks % of the group''s own rules:\n\n%\n\nThe loans were agreed in the room and approve_loan() never saw them, so no ceiling stopped them at the time. If the group means this recording to stand, set\n\n    v_acknowledge_rule_breaches := true;\n\nin the block above and run the file again. The list is written into the audit log for every loan.',
        v_assignment, array_length(v_breach_list, 1), v_breaches;
    end if;
  else
    v_breaches := '(none)';
  end if;

  -- ------------------------------------------------------------------ write
  -- Pending first, then moved to active: that UPDATE is what fires the app's own
  -- 'loan_active' notification, so borrowers hear about it in the usual words.
  for r in select * from op_meeting_loans order by seq loop
    insert into loans (member_id, principal, status, requested_at)
    values (r.member_id, r.principal, 'pending', v_issued_at)
    returning id into v_loan_id;

    update op_meeting_loans set loan_id = v_loan_id where seq = r.seq;

    update loans
       set status                 = 'active',
           approved_at            = v_issued_at,
           approved_by            = null,   -- agreed in the meeting, not in the app
           disbursed_at           = v_issued_at,
           disbursement_proof_url = null,
           outstanding_principal  = r.principal,
           interest_rate          = v_rate
     where id = v_loan_id;

    v_interest := round(r.principal * v_rate);

    for v_n in 1..v_months loop
      insert into loan_installments
        (loan_id, installment_number, due_date, principal_due, interest_due, penalty_rate)
      values (
        v_loan_id,
        v_n,
        -- The meeting in the n-th month after the one these were issued at —
        -- the same expression approve_loan uses (043), anchored to the meeting
        -- date rather than to today.
        meeting_day((v_issued_at::date + (v_n || ' month')::interval)::date),
        case when v_n = v_months then r.principal else 0 end,
        v_interest,
        v_penalty
      );
    end loop;

    insert into audit_log (actor_id, action, target_type, target_id, details)
    values (null, 'loan_recorded_at_meeting', 'loan', v_loan_id,
            jsonb_build_object(
              'member_id',     r.member_id,
              'principal',     r.principal,
              'issued_at',     v_issued_at,
              'interest_rate', v_rate,
              'months',        v_months,
              'rule_breaches', v_breaches,
              'note', 'Hand-run operations file. The group agreed and disbursed '
                      'this at the meeting of 2026-09-26; approve_loan() never '
                      'ran, so none of its ceilings were applied. See '
                      'supabase/operations/2026-09-29_meeting_loans_issued.sql.'));
  end loop;

  raise notice E'Recorded % loans totalling % TZS. Pool % -> %.\n%\nRule breaches: %',
    v_count, v_total, v_pool, v_pool - v_total, v_assignment, v_breaches;
end $$;

alter table loans enable trigger on_new_loan;

commit;

-- --------------------------------------------------------------------------
-- Verify. Thirteen active loans totalling 3,932,700, a pool of exactly 0, and
-- `balanced` still true — lending moves money between assets, it does not
-- create or destroy any.
-- --------------------------------------------------------------------------

select p.full_name,
       l.principal,
       l.outstanding_principal,
       l.interest_rate,
       l.disbursed_at
  from loans l join profiles p on p.id = l.member_id
 where l.status = 'active'
 order by p.full_name;

select i.due_date,
       count(*)              as installments,
       sum(i.interest_due)   as interest_due,
       sum(i.principal_due)  as principal_due,
       sum(i.total_due)      as total_due
  from loan_installments i
  join loans l on l.id = i.loan_id
 where l.status = 'active'
 group by i.due_date
 order by i.due_date;

select 'loans'        as check, (select count(*)::text from loans where status = 'active') as value
union all select 'lent out',    (select coalesce(sum(principal), 0)::text from loans where status = 'active')
union all select 'pool',        (select pool_tzs::text          from v_pool_reconciliation)
union all select 'outstanding', (select outstanding_tzs::text   from v_pool_reconciliation)
union all select 'total assets',(select total_assets_tzs::text  from v_pool_reconciliation)
union all select 'difference',  (select difference_tzs::text    from v_pool_reconciliation)
union all select 'balanced',    (select balanced::text          from v_pool_reconciliation);
