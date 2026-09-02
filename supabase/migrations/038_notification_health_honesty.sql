-- 038_notification_health_honesty.sql — make the reminder banner name the real cause.
--
-- 032 added `v_notification_health` so a queue that fills without draining could
-- not go unnoticed again. It worked: the admin dashboard raised the banner. But
-- the reason it printed was wrong, in a way that argued against acting on it.
--
-- `last_error` was "the newest row carrying any error at all":
--
--     WHERE d.last_error IS NOT NULL ORDER BY d.created_at DESC LIMIT 1
--
-- with no filter on status. The only rows with an error were the ones 032 itself
-- retired in its backfill — status 'skipped', last_error 'expired unsent — queued
-- before dispatch was connected'. Rows queued *since* have never been attempted
-- (nothing is draining them), so their last_error is NULL and they can never win
-- that ORDER BY.
--
-- So the banner reported a historical, already-retired batch as the current
-- fault. Read plainly it says "some old messages expired" — which sounds
-- self-limiting, and past. The truth was "dispatch has never run at all, and the
-- queue has been filling ever since". An admin who believed the banner would
-- reasonably decide to do nothing.
--
-- Two changes:
--
--   1. `last_error` now only considers rows that are still a live problem —
--      'queued' (the dispatcher writes the blocking reason onto the row it
--      stopped at, e.g. Beem code 102 "insufficient balance") or 'failed'
--      within the same 7-day window `failed_7d` already uses. 'skipped' is
--      retired-by-design and never a live cause.
--
--   2. New `never_sent` column: TRUE when no delivery has EVER succeeded. That
--      is the difference between "this was working and has now stopped" and
--      "this was never connected", which need different actions from an admin
--      and until now looked identical.
--
-- CREATE OR REPLACE VIEW can only APPEND columns, so never_sent goes last even
-- though it reads better beside last_sent_at.
--
-- Requires 032.

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
  -- Only rows that still represent something wrong. A blocked batch leaves its
  -- reason on a row that stays 'queued' (the dispatcher deliberately does not
  -- burn an attempt), so queued rows must stay in scope.
  (SELECT d.last_error
     FROM notification_deliveries d
    WHERE d.last_error IS NOT NULL
      AND d.status IN ('queued', 'failed')
      AND d.created_at > now() - interval '7 days'
    ORDER BY d.created_at DESC
    LIMIT 1)                                                            AS last_error,
  -- No successful delivery, ever. With stuck > 0 this means the drain was never
  -- connected, rather than connected and since broken.
  (max(sent_at) IS NULL)                                                AS never_sent
FROM notification_deliveries;

GRANT SELECT ON v_notification_health TO authenticated;

-- Verify:
--   select * from v_notification_health;
--
-- Expected on a system where dispatch was never connected: stuck > 0,
-- never_sent = true, last_error = NULL (nothing has been attempted, so nothing
-- has recorded a reason — the absence is itself the signal).
