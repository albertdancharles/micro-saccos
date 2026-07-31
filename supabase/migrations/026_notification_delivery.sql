-- 026_notification_delivery.sql — get reminders off the dashboard and onto phones.
--
-- 009 built a good notification system that nobody ever sees: it writes rows to
-- `notifications`, which only surface when a member opens the PWA. The members who
-- most need a reminder are exactly the ones who are not opening it.
--
-- ONE OUTBOX, MANY CHANNELS. A trigger on `notifications` INSERT enqueues a
-- delivery row per channel the recipient has enabled, so every existing trigger in
-- 009 — and every notification added since — gains external delivery without being
-- touched. An Edge Function drains the outbox.
--
--   push      free, no vendor, needs the PWA installed
--   sms       reaches feature phones; costs ~TZS 20–30 a message
--   whatsapp  same outbox, behind a flag
--
-- COST GUARD. `notification_deliveries` is deduped per (recipient, kind, dedupe_key)
-- so a member who is a month overdue is not billed an SMS every single day. The
-- daily reminder job builds its dedupe key from the obligation and the week.
--
-- Requires 021 (v_fee_status_money / v_installment_status_money with `remaining`).

-- --------------------------------------------------------------------------
-- 1. Contact & channel preferences
-- --------------------------------------------------------------------------

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS phone_e164   text,
  ADD COLUMN IF NOT EXISTS sms_opt_in   boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS push_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS preferred_language text NOT NULL DEFAULT 'sw';

-- Tanzanian numbers are entered every which way — 0712…, 255712…, +255 712 …
-- SMS needs one canonical form, so normalise to E.164 (+255…) once, here, rather
-- than in three different places at send time.
CREATE OR REPLACE FUNCTION to_e164(p_phone text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_phone IS NULL THEN NULL
    WHEN digits = ''     THEN NULL
    -- already international
    WHEN left(digits, 3) = '255' AND length(digits) = 12 THEN '+' || digits
    -- local 0712345678
    WHEN left(digits, 1) = '0'   AND length(digits) = 10 THEN '+255' || substring(digits from 2)
    -- bare 712345678
    WHEN length(digits) = 9                              THEN '+255' || digits
    ELSE NULL
  END
  FROM (SELECT regexp_replace(COALESCE(p_phone, ''), '[^0-9]', '', 'g') AS digits) d;
$$;

UPDATE profiles SET phone_e164 = to_e164(phone_number)
 WHERE phone_e164 IS NULL AND phone_number IS NOT NULL;

-- Web Push subscriptions. One member can have several (phone + laptop).
CREATE TABLE IF NOT EXISTS push_subscriptions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id  uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  endpoint   text NOT NULL UNIQUE,
  p256dh     text NOT NULL,
  auth       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_ok_at timestamptz
);

ALTER TABLE push_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Members manage own push subscriptions" ON push_subscriptions;
CREATE POLICY "Members manage own push subscriptions" ON push_subscriptions
  FOR ALL USING (member_id = auth.uid()) WITH CHECK (member_id = auth.uid());

GRANT SELECT, INSERT, DELETE ON push_subscriptions TO authenticated;

-- --------------------------------------------------------------------------
-- 2. The outbox
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS notification_deliveries (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  notification_id uuid REFERENCES notifications(id) ON DELETE CASCADE,
  recipient_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  channel         text NOT NULL CHECK (channel IN ('push', 'sms', 'whatsapp')),
  address         text NOT NULL,          -- E.164 number, or a push endpoint
  title           text NOT NULL,
  body            text,
  status          text NOT NULL DEFAULT 'queued'
                    CHECK (status IN ('queued', 'sent', 'failed', 'skipped')),
  attempts        int NOT NULL DEFAULT 0,
  last_error      text,
  -- Dedupe: one delivery per recipient per logical event. NULL means "always send".
  dedupe_key      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  sent_at         timestamptz
);

CREATE INDEX IF NOT EXISTS notification_deliveries_queued_idx
  ON notification_deliveries (status, created_at) WHERE status = 'queued';
CREATE UNIQUE INDEX IF NOT EXISTS notification_deliveries_dedupe_idx
  ON notification_deliveries (recipient_id, channel, dedupe_key)
  WHERE dedupe_key IS NOT NULL;

ALTER TABLE notification_deliveries ENABLE ROW LEVEL SECURITY;

-- Delivery records carry phone numbers, so only admins (and the owner) see them.
DROP POLICY IF EXISTS "Read own or all deliveries" ON notification_deliveries;
CREATE POLICY "Read own or all deliveries" ON notification_deliveries
  FOR SELECT USING (recipient_id = auth.uid() OR is_admin());

GRANT SELECT ON notification_deliveries TO authenticated;

-- --------------------------------------------------------------------------
-- 3. enqueue_delivery — the one place that decides which channels to use.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION enqueue_delivery(
  p_recipient uuid, p_title text, p_body text,
  p_notification_id uuid DEFAULT NULL, p_dedupe_key text DEFAULT NULL
)
RETURNS void AS $$
DECLARE
  v_profile profiles%ROWTYPE;
BEGIN
  SELECT * INTO v_profile FROM profiles WHERE id = p_recipient;
  IF v_profile.id IS NULL OR v_profile.is_active = false THEN RETURN; END IF;

  -- Push: one row per registered device.
  IF v_profile.push_enabled THEN
    INSERT INTO notification_deliveries
      (notification_id, recipient_id, channel, address, title, body, dedupe_key)
    SELECT p_notification_id, p_recipient, 'push', ps.endpoint, p_title, p_body,
           CASE WHEN p_dedupe_key IS NULL THEN NULL ELSE p_dedupe_key || ':' || ps.id END
      FROM push_subscriptions ps
     WHERE ps.member_id = p_recipient
    ON CONFLICT DO NOTHING;
  END IF;

  -- SMS: costs money, so it needs an opted-in member AND a usable number.
  IF v_profile.sms_opt_in AND v_profile.phone_e164 IS NOT NULL THEN
    INSERT INTO notification_deliveries
      (notification_id, recipient_id, channel, address, title, body, dedupe_key)
    VALUES (p_notification_id, p_recipient, 'sms', v_profile.phone_e164,
            p_title, p_body, p_dedupe_key)
    ON CONFLICT DO NOTHING;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Every notification 009 (or anything since) writes now also goes out externally.
CREATE OR REPLACE FUNCTION fan_out_notification()
RETURNS trigger AS $$
BEGIN
  PERFORM enqueue_delivery(NEW.recipient_id, NEW.title, NEW.body, NEW.id, NULL);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS on_notification_fan_out ON notifications;
CREATE TRIGGER on_notification_fan_out
  AFTER INSERT ON notifications
  FOR EACH ROW EXECUTE FUNCTION fan_out_notification();

-- --------------------------------------------------------------------------
-- 4. The daily reminder sweep.
--
--    Runs once a morning. Reminds about anything due in the next 3 days and
--    anything already overdue. The dedupe key includes the ISO week, so an overdue
--    member is nudged weekly rather than every single day — the difference between
--    a helpful reminder and an SMS bill nobody agreed to.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION send_due_reminders()
RETURNS int AS $$
DECLARE
  r      record;
  v_week text := to_char(today_eat(), 'IYYY-IW');
  v_n    int := 0;
BEGIN
  -- Monthly fees: due soon, or already overdue.
  FOR r IN
    SELECT f.member_id, f.id, f.due_date, f.total_with_penalty, f.computed_status
      FROM v_fee_status_money f
     WHERE f.computed_status <> 'paid'
       AND f.remaining > 0
       AND f.due_date <= today_eat() + 3
  LOOP
    PERFORM enqueue_delivery(
      r.member_id,
      CASE WHEN r.computed_status = 'overdue' THEN 'Monthly fee overdue' ELSE 'Monthly fee due soon' END,
      CASE WHEN r.computed_status = 'overdue'
           THEN 'Your monthly fee of ' || r.total_with_penalty || ' TZS is overdue. Pay in the app to stop the penalty growing.'
           ELSE 'Your monthly fee of ' || r.total_with_penalty || ' TZS is due on ' || r.due_date || '.'
      END,
      NULL,
      'fee:' || r.id || ':' || v_week
    );
    v_n := v_n + 1;
  END LOOP;

  -- Loan installments: same rule.
  FOR r IN
    SELECT l.member_id, i.id, i.due_date, i.total_with_penalty, i.computed_status
      FROM v_installment_status_money i
      JOIN loans l ON l.id = i.loan_id
     WHERE i.computed_status NOT IN ('paid', 'cancelled')
       AND i.remaining > 0
       AND l.status = 'active'
       AND i.due_date <= today_eat() + 3
  LOOP
    PERFORM enqueue_delivery(
      r.member_id,
      CASE WHEN r.computed_status = 'overdue' THEN 'Loan repayment overdue' ELSE 'Loan repayment due soon' END,
      CASE WHEN r.computed_status = 'overdue'
           THEN 'Your loan repayment of ' || r.total_with_penalty || ' TZS is overdue. Pay in the app to stop the penalty growing.'
           ELSE 'Your loan repayment of ' || r.total_with_penalty || ' TZS is due on ' || r.due_date || '.'
      END,
      NULL,
      'inst:' || r.id || ':' || v_week
    );
    v_n := v_n + 1;
  END LOOP;

  -- Share-outs waiting to be collected.
  FOR r IN
    SELECT d.member_id, d.id, d.total_payout_tzs
      FROM distributions d
     WHERE d.status = 'pending'
  LOOP
    PERFORM enqueue_delivery(
      r.member_id,
      'Your share-out is waiting',
      r.total_payout_tzs || ' TZS is ready for you from the last cycle.',
      NULL,
      'dist:' || r.id || ':' || v_week
    );
    v_n := v_n + 1;
  END LOOP;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (NULL, 'send_due_reminders', 'system', NULL,
          jsonb_build_object('reminders', v_n, 'week', v_week));

  RETURN v_n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. Member self-service for channels + push registration.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION update_notification_prefs(
  p_sms_opt_in boolean, p_push_enabled boolean, p_language text DEFAULT NULL
)
RETURNS void AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE profiles
     SET sms_opt_in   = COALESCE(p_sms_opt_in, sms_opt_in),
         push_enabled = COALESCE(p_push_enabled, push_enabled),
         preferred_language = COALESCE(NULLIF(trim(p_language), ''), preferred_language),
         -- Keep the canonical number in step with whatever they last saved.
         phone_e164   = COALESCE(to_e164(phone_number), phone_e164)
   WHERE id = auth.uid();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 6. Schedule.
--
--    Same approach as 017: call the SQL directly from pg_cron rather than standing
--    up an Edge Function + pg_net just to schedule it. The DISPATCH job (which does
--    need network access) is the Edge Function `dispatch-notifications`; wire it up
--    per supabase/README.md once its secrets are set.
--
--    Times are UTC. 05:00 UTC = 08:00 EAT.
-- --------------------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('daily-due-reminders')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'daily-due-reminders');
    PERFORM cron.schedule('daily-due-reminders', '0 5 * * *', 'SELECT send_due_reminders();');
  ELSE
    RAISE NOTICE 'pg_cron is not installed — enable it in the Supabase dashboard, then re-run this block.';
  END IF;
END;
$$;
