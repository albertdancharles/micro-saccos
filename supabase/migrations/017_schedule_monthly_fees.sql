-- 017: Schedule monthly fee generation via pg_cron.
--
-- ensure_current_fees() (migration 005) is a SECURITY DEFINER, idempotent upsert that
-- does the same thing as the generate-monthly-fees Edge Function but in pure SQL with
-- no auth.uid() dependency. Scheduling it directly is simpler than deploying the Edge
-- Function + a pg_net HTTP call, and needs no service-role key. Run this once in the
-- Supabase SQL editor.

-- 1. Enable pg_cron (also available via Dashboard → Database → Extensions).
create extension if not exists pg_cron;

-- 2. Schedule for the 1st of each month at 03:00 UTC (= 06:00 EAT, safely inside the
--    1st in East Africa Time). Re-running with the same job name replaces the job.
--    The function uses today_eat() internally, so the exact run time only needs to
--    land on the 1st in EAT.
select cron.schedule(
  'generate-monthly-fees',
  '0 3 1 * *',
  $$ select ensure_current_fees(); $$
);

-- Verify:
--   select jobid, jobname, schedule, command, active from cron.job;
--   select * from cron.job_run_details order by start_time desc limit 5;
--
-- To remove:  select cron.unschedule('generate-monthly-fees');
