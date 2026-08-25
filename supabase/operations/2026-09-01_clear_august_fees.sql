-- 2026-09-01_clear_august_fees.sql
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

delete from monthly_fees where period = date '2026-08-01';

-- Expect only Sep 2026 (and later), and balanced = true.
select to_char(period, 'Mon YYYY') as period, count(*) as rows, sum(amount) as total
  from monthly_fees group by period order by min(period);

select balanced, pool_tzs from v_pool_reconciliation;
