-- 2026-08-25_opening_balance_reset.sql
--
-- NOT A MIGRATION. Run once, by hand, against the live project. See ./README.md.
--
-- WHY. The database was rebuilt by the destructive cutover on 2026-06-20 and the group
-- never recorded a payment through it: 7 members, 0 approved submissions, 0 fees with
-- money on them, pool 0.00. What DID accumulate was obligation — ensure_current_fees()
-- generated a fee every month regardless, leaving 17 unpaid rows worth 170,000 with
-- 6,500 of penalty accrued against months when nobody was using the app.
--
-- The group's decision: waive all of it, start collecting in September 2026, and load
-- per-member opening balances separately.
--
-- WHY DELETE RATHER THAN WAIVE THE RATE. penalty_rate is snapshotted onto each
-- monthly_fees row at creation (migration 020) and v_fee_status_money reads the row's
-- own column, not the live setting. So lowering the group setting does nothing to rows
-- that already exist. Deleting them is what actually clears the debt AND the penalty.
--
-- AFTER THIS RUNS, AUGUST COMES BACK. ensure_current_fees() recreates the CURRENT
-- month for every active member the next time an admin opens the dashboard, or when the
-- pg_cron job fires. That is normal operation resuming, not a failure. It returns with
-- penalty_rate 0 because the setting is changed below, before any regeneration.
-- Clear it with ./2026-09-01_clear_august_fees.sql once September has started.

begin;

do $$
declare
  v_rows int; v_base numeric; v_penalty numeric;
begin
  -- Refuse if any fee has money on it. v_group_pool sums monthly_fees.amount_paid, so
  -- deleting a paid fee removes cash from the pool and breaks the assets = claims
  -- identity with no error and no warning. Nothing has money on it as of 2026-08-25;
  -- this guard is what makes the script still safe if that changes before it is run.
  if exists (select 1 from monthly_fees
              where amount_paid > 0 or penalty_collected > 0) then
    raise exception
      'ABORTED: % fee row(s) have money recorded against them. Deleting those would '
      'break the pool identity (v_group_pool sums monthly_fees.amount_paid). '
      'Investigate before resetting.',
      (select count(*) from monthly_fees where amount_paid > 0 or penalty_collected > 0);
  end if;

  -- Measure at run time. An earlier draft wrote the figures in as literals, which would
  -- have recorded a number that was true when it was typed rather than when it ran.
  select count(*),
         coalesce(sum(amount - amount_paid), 0),
         coalesce(sum(penalty_due), 0)
    into v_rows, v_base, v_penalty
    from v_fee_status_money
   where status <> 'paid';

  -- Order matters: new fee rows snapshot penalty_rate at creation, so this has to land
  -- before anything regenerates a fee or the new rows inherit 5%.
  update group_settings
     set value = 0, updated_at = now()
   where key = 'penalty_rate';

  delete from monthly_fees;

  insert into audit_log (actor_id, action, target_type, target_id, details)
  values (null, 'opening_balance_reset', 'system', null,
          jsonb_build_object(
            'fees_deleted',        v_rows,
            'base_cleared',        v_base,
            'penalty_waived',      v_penalty,
            'penalty_rate_set_to', 0,
            'note', 'Clean slate. Group starts collecting September 2026.'));

  raise notice 'Deleted % fee row(s). Cleared % base, waived % penalty.',
    v_rows, v_base, v_penalty;
end $$;

commit;

-- Expect: 0 / 0.0000 / 0 / true
select 'fees remaining' as check, count(*)::text as value from monthly_fees
union all select 'penalty_rate', (select value::text from group_settings where key='penalty_rate')
union all select 'pool',         (select pool_tzs::text from v_pool_reconciliation)
union all select 'balanced',     (select balanced::text from v_pool_reconciliation);
