-- 032_notification_dispatch.sql — connect the outbox to the outside world.
--
-- 026 built the reminder pipeline and scheduled the sweep, but the last hop was
-- left as a manual step and never taken: `dispatch-notifications` was never
-- deployed and no job ever drained `notification_deliveries`. The daily sweep has
-- been running correctly ever since — writing ~10 reminders a week into a queue
-- that nothing reads. Every audit row says it worked. Not one message was sent.
--
-- Three things follow from that, and this migration is all three:
--
--   1. RETIRE THE BACKLOG. Those queued rows are weeks of "your fee is due in 3
--      days" about dates long past. Delivering them the moment dispatch is
--      connected would spend real money to tell members things that are no longer
--      true, so they are marked skipped instead. Only fresh rows go out.
--
--   2. SCHEDULE THE DRAIN. `schedule_notification_drain()` takes the URL and the
--      shared secret as arguments rather than hard-coding them, so the secret is
--      typed once into the SQL editor and never lands in git.
--
--   3. MAKE IT VISIBLE. `v_notification_health` is what would have caught this in
--      week one: a queue that is filling but not draining.
--
-- Requires 026.

-- --------------------------------------------------------------------------
-- 1. Retire the backlog.
--
--    48 hours is the same window the Edge Function enforces on every run
--    (DISPATCH_MAX_AGE_HOURS). A reminder older than that has outlived the thing
--    it was reminding about.
-- --------------------------------------------------------------------------

UPDATE notification_deliveries
   SET status     = 'skipped',
       last_error = 'expired unsent — queued before dispatch was connected'
 WHERE status = 'queued'
   AND created_at < now() - interval '48 hours';

-- --------------------------------------------------------------------------
-- 2. Schedule the drain.
--
--    The sweep in 026 is pure SQL, so pg_cron calls it directly. Draining is
--    different: it needs the network, so it goes out through pg_net to the Edge
--    Function. Both are reached with dynamic SQL so this migration still applies
--    to a plain Postgres — the test harness has no pg_net, and nothing here
--    touches it until the function is actually called.
--
--    Run once, in the SQL editor, with your own values:
--
--      select schedule_notification_drain(
--        'https://<project-ref>.supabase.co/functions/v1/dispatch-notifications',
--        '<the DISPATCH_SECRET set in Edge Function secrets>'
--      );
--
--    Re-run it to rotate the secret or change the cadence; it replaces the job.
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

-- --------------------------------------------------------------------------
-- 3. Health.
--
--    security_invoker, so it inherits the RLS on notification_deliveries: an
--    admin sees the whole outbox, a member sees only their own rows.
--
--    `stuck` is the number that matters. Queued rows older than two hours mean
--    the drain job is not running — which is exactly the state this project was
--    in, undetected, for weeks.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_notification_health
WITH (security_invoker = true) AS
SELECT
  count(*) FILTER (WHERE status = 'queued')                             AS queued,
  count(*) FILTER (WHERE status = 'queued'
                     AND created_at < now() - interval '2 hours')       AS stuck,
  count(*) FILTER (WHERE status = 'sent'
                     AND sent_at > now() - interval '7 days')           AS sent_7d,
  count(*) FILTER (WHERE status = 'failed'
                     AND created_at > now() - interval '7 days')        AS failed_7d,
  count(*) FILTER (WHERE status = 'skipped'
                     AND created_at > now() - interval '7 days')        AS skipped_7d,
  max(sent_at)                                                          AS last_sent_at,
  (SELECT d.last_error
     FROM notification_deliveries d
    WHERE d.last_error IS NOT NULL
    ORDER BY d.created_at DESC
    LIMIT 1)                                                            AS last_error
FROM notification_deliveries;

GRANT SELECT ON v_notification_health TO authenticated;

-- Verify:
--   select * from v_notification_health;
--   select jobid, jobname, schedule, active from cron.job;
--   select * from cron.job_run_details where jobname = 'drain-notification-outbox'
--     order by start_time desc limit 5;
--
-- To stop the drain:  select cron.unschedule('drain-notification-outbox');
