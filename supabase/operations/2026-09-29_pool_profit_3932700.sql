-- 2026-09-29_pool_profit_3932700.sql
--
-- NOT A MIGRATION. Run once, by hand, against the live project. See ./README.md.
--
-- WHAT. Raises the group pool from 3,220,000.00 to 3,932,700.00 TZS — a single
-- approved pool_adjustments row of +712,700.00 — recording the profit the group
-- earned in the months before any of this was in the app.
--
--     before:  3,220,000.00   (14 members x 230,000 opening savings)
--     delta:    +712,700.00   (retained profit, earned before 2026-09-29)
--     after:   3,932,700.00
--
-- ONLY RUN THIS IF THE 712,700 IS REALLY IN THE GROUP'S ACCOUNT. v_group_pool is
-- liquid, loanable cash. Money added here is money the app will offer to lend.
--
-- WHY A POOL ADJUSTMENT AND NOT A SAVINGS ADJUSTMENT. This profit belongs to the
-- group, not to any one member. A savings_adjustments row would put it on named
-- members' balances, raise each of their 5x loan ceilings, and earn them
-- member-months in the share-out weighting. None of that is what the group
-- decided. pool_adjustments is the table for group-level money with no member
-- attached (015), and v_pool_reconciliation carries it as its own claim term
-- (027: `pool_adjustments_tzs`), so the books stay balanced with no further entry.
--
-- WHY NOT earnings_ledger, AND WHAT THAT COSTS — READ THIS BEFORE RUNNING.
--
--   earnings_ledger is where profit normally lands, and cycle_earnings() (023)
--   reads it to decide what a share-out pays out. But the ledger is NOT a term in
--   v_group_pool: interest reaches the pool through the installment payment that
--   carried it, not through the ledger row. There is no such payment here — this
--   is historical profit being asserted, not collected — so a ledger row alone
--   would raise claims by 712,700 with nothing on the assets side, and
--   v_pool_reconciliation would correctly report the books as broken. Writing
--   BOTH a ledger row and this adjustment is worse: the same 712,700 would be
--   claimed twice.
--
--   The cost of doing it this way: this money is group capital, not cycle
--   earnings. close_cycle() will NOT include it in the earnings pot, and in
--   full_shareout mode it will not come back as anyone's returned capital either
--   — it stays in the group and rolls into the next cycle. If the group means
--   this profit to be SHARED OUT, that has to be a decision at close time, or
--   the 712,700 has to be split across members as savings adjustments instead.
--   Do not "fix" it later by adding an earnings_ledger row on top of this one.
--
-- WHAT ELSE MOVES. Every loan ceiling rises, because the cap is
-- min(5x contribution, 25% of pool) (031, group_settings). At 230,000 saved the
-- 5x arm is 1,150,000 and the 25% arm was the binding one at 805,000; it becomes
-- 983,175. So the most any member can borrow goes up by 178,175.
--
-- NOBODY IS NOTIFIED. No member's balance changes, so there is nothing to tell
-- anyone individually. The change is visible to every member on the totals card
-- and, itemised as "Admin adjustments", in the reconciliation banner.

begin;

do $$
declare
  -- The three things to check before running.
  v_expected_pool numeric(14,2) := 3220000.00;
  v_target_pool   numeric(14,2) := 3932700.00;
  v_reason        text := 'Retained profit from months before the app, recorded by group decision, 2026-09-29.';

  v_delta   numeric(14,2) := v_target_pool - v_expected_pool;
  v_actual  numeric(14,2);
begin
  -- Idempotency. The reason text is the marker: a second run would add another
  -- 712,700 to a pool that already has it, and nothing about the duplicate row
  -- would look wrong to anyone reading the table later.
  if exists (select 1 from pool_adjustments
              where reason = v_reason and status = 'approved') then
    raise exception
      'ABORTED: a pool adjustment with this exact reason already exists. '
      'This file has been run.';
  end if;

  -- The pool must be where this file thinks it is. If it is not, the group is
  -- not looking at the books this decision was made against, and landing on
  -- 3,932,700 by adding a blind delta would be luck rather than arithmetic.
  select pool_balance_tzs into v_actual from v_group_pool;

  if v_actual <> v_expected_pool then
    raise exception
      'ABORTED: the pool is % , not the % this file was written against. '
      'Adding % would land on % , not the intended % . Work out why before running.',
      v_actual, v_expected_pool, v_delta, v_actual + v_delta, v_target_pool;
  end if;

  -- A pending in-app pool edit would be voted on against a pool this file has
  -- already moved. Let the admins settle it first.
  if exists (select 1 from pool_adjustments where status = 'pending') then
    raise exception
      'ABORTED: a pool edit is pending in the app. Approve or cancel it first.';
  end if;

  -- 1. The money. requested_by is NULL: no admin requested this in the app —
  --    the group decided it together, the same stance the opening-balance file
  --    took on 2026-09-29.
  insert into pool_adjustments (requested_by, delta, reason, status, applied_at)
  values (null, v_delta, v_reason, 'approved', now());

  -- 2. The trail — enough to reconstruct this from the audit log alone.
  insert into audit_log (actor_id, action, target_type, target_id, details)
  values (null, 'pool_retained_profit_load', 'pool', null,
          jsonb_build_object(
            'pool_before', v_expected_pool,
            'delta',       v_delta,
            'pool_after',  v_target_pool,
            'reason',      v_reason,
            'note', 'Hand-run operations file, not an in-app 2-of-N pool edit. '
                    'Group capital, NOT cycle earnings: cycle_earnings() reads '
                    'earnings_ledger and will not see this.'));

  raise notice 'Pool raised from % to % (+%).',
    v_expected_pool, v_target_pool, v_delta;
end $$;

commit;

-- --------------------------------------------------------------------------
-- Verify. `pool` must read 3932700.00 and `balanced` must be true — if it is
-- false, the identity broke and something above is wrong.
-- --------------------------------------------------------------------------

select 'pool'              as check, (select pool_tzs::text              from v_pool_reconciliation) as value
union all select 'capital',          (select member_capital_tzs::text    from v_pool_reconciliation)
union all select 'retained earnings',(select retained_earnings_tzs::text from v_pool_reconciliation)
union all select 'admin adjustments',(select pool_adjustments_tzs::text  from v_pool_reconciliation)
union all select 'difference',       (select difference_tzs::text        from v_pool_reconciliation)
union all select 'balanced',         (select balanced::text              from v_pool_reconciliation);

-- No member's savings should have moved. Every active member still reads what
-- they read before this file ran.
select p.full_name,
       coalesce((select sum(sa.delta) from savings_adjustments sa
                  where sa.target_member_id = p.id and sa.status = 'approved'), 0)
     + coalesce((select sum(mf.amount_paid) from monthly_fees mf
                  where mf.member_id = p.id), 0) as savings_total
  from profiles p
 where p.is_active = true
 order by p.full_name;
