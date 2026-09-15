-- 2026-09-01_clear_august_fees.sql
--
-- SUPERSEDED 2026-09-15 — NEVER RUN, DO NOT RUN.
--
-- The group ended up collecting August after all: on 2026-09-12 an admin recorded
-- August fees for 6 of 7 members (60,000 TZS paid). The August rows this deletes are no
-- longer unwanted regenerations — they are paid history. The DELETE below is commented
-- out so that pasting this file into the SQL editor cannot destroy it. Do not re-enable
-- it. The file stays only as a record of a plan that was dropped.
--
-- Nothing would catch the damage. Fee payments count on BOTH sides of the books —
-- monthly_fees.amount_paid is in v_group_pool and in member capital — so deleting paid
-- rows lowers assets and claims by the same 60,000 and v_pool_reconciliation still
-- says balanced = true. The money would just silently disappear.
--
-- Original intent, for the record:
--
-- NOT A MIGRATION. Run once, on or after 2026-09-01. See ./README.md.
--
-- The opening-balance reset deleted every fee row, but ensure_current_fees() recreates
-- the current month on the next admin dashboard load or pg_cron run — so August came
-- back. The group is not collecting for August; it starts in September. This removes it.
--
-- THE DATE IS A LITERAL ON PURPOSE. The obvious general form,
--
--     delete from monthly_fees where period < date_trunc('month', today_eat())::date;
--
-- is correct in September and destroys real paid history in any later month. A literal
-- can only ever hit August, whenever someone runs it.
--
-- Idempotent: if no admin opened the dashboard before September, August never
-- regenerated and this deletes nothing.

-- DISABLED — see the header. August fees are paid.
-- delete from monthly_fees where period = date '2026-08-01';

-- Read-only. Originally "expect only Sep 2026"; since 2026-09-12 August is real history.
select to_char(period, 'Mon YYYY') as period, count(*) as rows, sum(amount) as total
  from monthly_fees group by period order by min(period);

select balanced, pool_tzs from v_pool_reconciliation;
