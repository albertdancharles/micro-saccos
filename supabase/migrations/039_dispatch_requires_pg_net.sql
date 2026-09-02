-- 039_dispatch_requires_pg_net.sql — refuse to schedule a drain that cannot run.
--
-- 032 routes the drain through pg_net (`select net.http_post(...)`), because
-- draining needs the network and pg_cron alone cannot reach it. But it never
-- installs pg_net and never checks for it — unlike 017, which does
-- `create extension if not exists pg_cron`, and 026, which at least raises a
-- NOTICE when pg_cron is missing.
--
-- The consequence is the worst available failure mode. The command pg_cron
-- stores is just a string, so `schedule_notification_drain()` succeeds, prints
-- "scheduled as job N", and writes a satisfied row into audit_log. Every run
-- from then on fails with `schema "net" does not exist` — inside pg_cron, where
-- nobody is looking. The queue keeps filling. The dashboard says the job exists.
--
-- That is precisely the shape of failure 032 was written to eliminate: a
-- pipeline that reports success at every point an admin can see while
-- delivering nothing. It reproduced it one layer down.
--
-- Two changes:
--
--   1. Install pg_net where the platform allows it. Wrapped, because the SQL
--      test harness is a plain postgres:17-alpine with no pg_net package at
--      all — the extension is unavailable there, not merely un-created, so a
--      bare CREATE EXTENSION would abort the migration and take CI with it.
--
--   2. Make schedule_notification_drain() fail closed when pg_net is absent,
--      the same posture it already takes for a missing secret. Refusing to
--      create the job is strictly better than creating one that cannot work:
--      the error arrives in the SQL editor, where the person running it is
--      looking, instead of in a cron log fifteen minutes later.
--
-- Requires 032.

-- --------------------------------------------------------------------------
-- 1. Install pg_net if this platform has it.
-- --------------------------------------------------------------------------

DO $$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_net;
  EXCEPTION WHEN OTHERS THEN
    -- Plain Postgres (the test harness) has no pg_net to install. Not fatal:
    -- nothing in this migration calls net.* at apply time, and the guard below
    -- is what stops a broken job being scheduled on a box that lacks it.
    RAISE NOTICE 'pg_net is not available here (%) — enable it in Dashboard → Database → Extensions before scheduling the drain.', SQLERRM;
  END;
END;
$$;

-- --------------------------------------------------------------------------
-- 2. Fail closed without it.
--
--    Body is otherwise identical to 032; only the pg_net check is new.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION schedule_notification_drain(
  p_url      text,
  p_secret   text,
  p_schedule text DEFAULT '*/15 * * * *'
)
RETURNS text AS $$
DECLARE
  v_command text;
  v_jobid   bigint;
BEGIN
  -- This is run from the SQL editor, where there is no JWT and auth.uid() is NULL
  -- — so `NOT is_admin()` alone would lock the owner out of their own helper. The
  -- real gate is the REVOKE below: `authenticated` is never granted EXECUTE, so
  -- PostgREST cannot reach this at all. The check below only covers the case of a
  -- future caller that does arrive with a session.
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF COALESCE(p_url, '') = '' THEN
    RAISE EXCEPTION 'A function URL is required';
  END IF;
  -- The endpoint fails closed without a secret, so a job without one would only
  -- ever collect 503s. Better to refuse here than to schedule something useless.
  IF COALESCE(p_secret, '') = '' THEN
    RAISE EXCEPTION 'A dispatch secret is required — the endpoint refuses to run without one';
  END IF;
  -- The scheduled command is `select net.http_post(...)`. Without pg_net that is
  -- a job which fails every fifteen minutes inside pg_cron, where the failure is
  -- invisible — while the queue silently fills. Refuse, loudly, here instead.
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE EXCEPTION 'pg_net is not installed — the drain job would fail on every run. Enable it in Dashboard → Database → Extensions, then run this again.';
  END IF;

  -- pg_net lives outside the default search_path on Supabase, hence net.*.
  -- quote_literal on both values stops a stray quote in the secret from breaking
  -- the job definition.
  v_command := format(
    'select net.http_post(url := %s, headers := %s::jsonb, body := %s::jsonb)',
    quote_literal(p_url),
    quote_literal(json_build_object(
      'Content-Type',      'application/json',
      'x-dispatch-secret', p_secret
    )::text),
    quote_literal('{}')
  );

  -- Replace any previous definition — the secret may have been rotated.
  BEGIN
    EXECUTE format('SELECT cron.unschedule(%L)', 'drain-notification-outbox');
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- not scheduled yet: the normal first run
  END;

  EXECUTE format('SELECT cron.schedule(%L, %L, %L)',
                 'drain-notification-outbox', p_schedule, v_command)
    INTO v_jobid;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'schedule_notification_drain', 'system', NULL,
          jsonb_build_object('schedule', p_schedule, 'jobid', v_jobid));

  RETURN format('drain-notification-outbox scheduled as job %s (%s)', v_jobid, p_schedule);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION schedule_notification_drain(text, text, text) FROM public;

-- Verify:
--   select extname from pg_extension where extname in ('pg_cron', 'pg_net');
--   select jobid, jobname, schedule, active from cron.job;
--   select jobname, status, return_message, start_time
--     from cron.job_run_details
--    where jobname = 'drain-notification-outbox'
--    order by start_time desc limit 5;
