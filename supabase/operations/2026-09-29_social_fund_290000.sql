-- 2026-09-29_social_fund_290000.sql
--
-- NOT A MIGRATION. Run once, by hand, against the live project. See ./README.md.
--
-- WHAT. Raises the social fund (bima ya jamii) from 20,000.00 to 290,000.00 TZS
-- — a single social_fund_entries contribution row of 270,000.00.
--
--     before:   20,000.00
--     delta:  +270,000.00
--     after:   290,000.00
--
-- NOTHING ELSE MOVES, AND THAT IS BY DESIGN. The social fund is deliberately
-- outside v_group_pool (030): it is welfare money for funerals and medical
-- emergencies, not loanable capital. So this file does NOT change the pool, does
-- NOT change anyone's savings, does NOT raise any loan ceiling, and does NOT
-- touch v_pool_reconciliation. It only moves the balance on the social fund card.
--
-- WHY ONE GROUP-LEVEL ROW AND NOT ONE PER MEMBER. member_id is nullable on
-- social_fund_entries and is provenance only — the fund has no per-member
-- sub-balances, nothing reads member_id for money, and the fund is never shared
-- out. 270,000 across 14 members does not divide evenly either, so splitting it
-- would mean inventing 14 amounts nobody agreed. If the group does want the
-- contributions attributed member by member, replace the single insert in
-- section 1 with one row per member and keep the same reason text.
--
-- WHY NOT record_social_contribution(). That RPC is the in-app path: it needs an
-- auth.uid() for recorded_by and writes its own audit row. This is a balance the
-- group is asserting, not a contribution an admin keyed in, so recorded_by is
-- left NULL — the same stance ./2026-09-29_savings_opening_balance_230k.sql took.

begin;

do $$
declare
  -- The three things to check before running.
  v_expected_balance numeric(12,2) := 20000.00;
  v_target_balance   numeric(12,2) := 290000.00;
  v_occurred_at      timestamptz   := now();  -- backdate to the meeting if the group prefers
  v_reason           text := 'Social fund balance brought up to date by group decision, 2026-09-29.';

  v_delta  numeric(12,2) := v_target_balance - v_expected_balance;
  v_actual numeric(12,2);
begin
  -- Idempotency. The reason text is the marker: a second run would take the fund
  -- to 560,000 and the duplicate row would look entirely ordinary later.
  if exists (select 1 from social_fund_entries where reason = v_reason) then
    raise exception
      'ABORTED: a social fund entry with this exact reason already exists. '
      'This file has been run.';
  end if;

  -- The fund must be where this file thinks it is, for the same reason the pool
  -- file checks the pool: a blind delta lands on the right number only by luck.
  select balance_tzs into v_actual from v_social_fund;

  if v_actual <> v_expected_balance then
    raise exception
      'ABORTED: the social fund holds % , not the % this file was written against. '
      'Adding % would land on % , not the intended % . Work out why before running.',
      v_actual, v_expected_balance, v_delta, v_actual + v_delta, v_target_balance;
  end if;

  -- 1. The money. member_id NULL = the group's own contribution, attributable to
  --    no single member. recorded_by NULL: see the header.
  insert into social_fund_entries
    (member_id, kind, amount, reason, recorded_by, occurred_at)
  values (null, 'contribution', v_delta, v_reason, null, v_occurred_at);

  -- 2. The trail.
  insert into audit_log (actor_id, action, target_type, target_id, details)
  values (null, 'social_fund_balance_load', 'social_fund', null,
          jsonb_build_object(
            'balance_before', v_expected_balance,
            'delta',          v_delta,
            'balance_after',  v_target_balance,
            'occurred_at',    v_occurred_at,
            'reason',         v_reason,
            'note', 'Hand-run operations file, not an in-app contribution. '
                    'Welfare money: outside v_group_pool, not lendable, not shared out.'));

  raise notice 'Social fund raised from % to % (+%).',
    v_expected_balance, v_target_balance, v_delta;
end $$;

commit;

-- --------------------------------------------------------------------------
-- Verify. `balance_tzs` must read 290000.00, and the pool must be untouched.
-- --------------------------------------------------------------------------

select contributed_tzs, granted_tzs, balance_tzs from v_social_fund;

select kind, amount, reason, occurred_at
  from social_fund_entries
 order by occurred_at desc
 limit 10;

select 'pool'      as check, (select pool_tzs::text from v_pool_reconciliation) as value
union all select 'balanced', (select balanced::text from v_pool_reconciliation);
