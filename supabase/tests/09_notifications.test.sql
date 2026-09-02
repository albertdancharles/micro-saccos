-- 09_notifications.test.sql — the outbox, and the cost guard that keeps it cheap.
--
-- This is the one pipeline in the app that spends money on every row it writes.
-- The dedupe key is what stands between "a member who is a month overdue gets a
-- weekly nudge" and "a member who is a month overdue gets billed an SMS every
-- morning for thirty days" — and until now nothing tested it.
--
-- Also covers the delivery preconditions (opt-out, missing number, inactive
-- member), because every one of them is a silent way to text somebody who did not
-- agree to be texted.

DO $$
DECLARE
  v_admin  uuid;
  v_owing  uuid;
  v_quiet  uuid;   -- opted out of SMS
  v_nophone uuid;  -- opted in, but we have no number for them
  v_gone   uuid;   -- deactivated
  v_fee    uuid;
  v_n      int;
  v_health record;
BEGIN
  v_admin   := tests.make_admin('Notify Admin');
  v_owing   := tests.make_member('Notify Owing');
  v_quiet   := tests.make_member('Notify Quiet');
  v_nophone := tests.make_member('Notify Nophone');
  v_gone    := tests.make_member('Notify Gone');

  -- ==================================================== E.164 normalisation
  -- Members type their number every which way; SMS needs exactly one form.
  PERFORM tests.eq(to_e164('0712345678'),    '+255712345678', 'local 0-prefixed number');
  PERFORM tests.eq(to_e164('255712345678'),  '+255712345678', 'already international');
  PERFORM tests.eq(to_e164('+255 712 345 678'), '+255712345678', 'spaces and a plus');
  PERFORM tests.eq(to_e164('712345678'),     '+255712345678', 'bare nine digits');
  PERFORM tests.eq(to_e164('12345'),         NULL,            'too short is rejected, not guessed');
  PERFORM tests.eq(to_e164(NULL),            NULL,            'null stays null');

  UPDATE profiles SET phone_number = '0712345678', phone_e164 = to_e164('0712345678'),
                      sms_opt_in = true  WHERE id = v_owing;
  UPDATE profiles SET phone_number = '0713333333', phone_e164 = to_e164('0713333333'),
                      sms_opt_in = false WHERE id = v_quiet;
  UPDATE profiles SET phone_e164 = NULL, sms_opt_in = true WHERE id = v_nophone;
  UPDATE profiles SET phone_number = '0714444444', phone_e164 = to_e164('0714444444'),
                      sms_opt_in = true, is_active = false WHERE id = v_gone;

  -- ==================================================== who may be texted
  PERFORM enqueue_delivery(v_owing,   'Hello', 'body', NULL, NULL);
  PERFORM enqueue_delivery(v_quiet,   'Hello', 'body', NULL, NULL);
  PERFORM enqueue_delivery(v_nophone, 'Hello', 'body', NULL, NULL);
  PERFORM enqueue_delivery(v_gone,    'Hello', 'body', NULL, NULL);

  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notification_deliveries WHERE recipient_id = v_owing),
    1, 'an opted-in member with a number gets one SMS row');
  PERFORM tests.eq(
    (SELECT address FROM notification_deliveries WHERE recipient_id = v_owing),
    '+255712345678', 'and it goes to the canonical number, not the raw one');
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notification_deliveries WHERE recipient_id = v_quiet),
    0, 'opting out of SMS means no SMS');
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notification_deliveries WHERE recipient_id = v_nophone),
    0, 'no number means nothing to send to');
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notification_deliveries WHERE recipient_id = v_gone),
    0, 'a deactivated member is not texted');

  -- Push is only queued once the member has actually registered a device.
  UPDATE profiles SET push_enabled = true WHERE id = v_owing;
  PERFORM enqueue_delivery(v_owing, 'Push?', 'body', NULL, NULL);
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notification_deliveries
      WHERE recipient_id = v_owing AND channel = 'push'),
    0, 'push_enabled with no subscription queues nothing');

  INSERT INTO push_subscriptions (member_id, endpoint, p256dh, auth)
  VALUES (v_owing, 'https://push.test/endpoint-1', 'k', 'a');
  PERFORM enqueue_delivery(v_owing, 'Push!', 'body', NULL, NULL);
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notification_deliveries
      WHERE recipient_id = v_owing AND channel = 'push'),
    1, 'a registered device gets a push row');

  -- Push is free; everything below is about the channel that costs money, so take
  -- the device back out of the picture and count SMS rows on their own.
  DELETE FROM push_subscriptions WHERE member_id = v_owing;
  UPDATE profiles SET push_enabled = false WHERE id = v_owing;
  DELETE FROM notification_deliveries;

  -- ==================================================== the fan-out trigger
  -- Every notification 009 writes — and everything added since — must reach the
  -- outbox without the calling code knowing the outbox exists.
  INSERT INTO notifications (recipient_id, kind, title, body)
  VALUES (v_owing, 'test', 'Fanned out', 'body');
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notification_deliveries
      WHERE recipient_id = v_owing AND channel = 'sms'),
    1, 'an in-app notification fans out to SMS on its own');

  DELETE FROM notification_deliveries;

  -- ==================================================== the cost guard
  -- Same logical event twice: the second must be swallowed by the dedupe index.
  PERFORM enqueue_delivery(v_owing, 'Fee overdue', 'body', NULL, 'fee:abc:2026-32');
  PERFORM enqueue_delivery(v_owing, 'Fee overdue', 'body', NULL, 'fee:abc:2026-32');
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notification_deliveries WHERE recipient_id = v_owing),
    1, 'the same obligation in the same week is billed once, not twice');

  -- A different week is a genuinely new nudge and must get through.
  PERFORM enqueue_delivery(v_owing, 'Fee overdue', 'body', NULL, 'fee:abc:2026-33');
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notification_deliveries WHERE recipient_id = v_owing),
    2, 'next week the member is nudged again');

  -- A NULL key means "always send" — one-off events must never be deduped away.
  DELETE FROM notification_deliveries;
  PERFORM enqueue_delivery(v_owing, 'Payment approved', 'body', NULL, NULL);
  PERFORM enqueue_delivery(v_owing, 'Payment approved', 'body', NULL, NULL);
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notification_deliveries WHERE recipient_id = v_owing),
    2, 'a null dedupe key always sends');

  DELETE FROM notification_deliveries;

  -- ==================================================== the daily sweep
  -- An unpaid fee for last month. due_date is derived (period + 1 month - 1 day),
  -- so this one is already overdue. send_due_reminders() runs every morning, so
  -- running it twice must still only produce one message.
  v_fee := tests.give_fee(v_owing, (date_trunc('month', today_eat()) - INTERVAL '1 month')::date);

  v_n := send_due_reminders();
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notification_deliveries WHERE recipient_id = v_owing),
    1, 'the sweep reminds an overdue member');

  PERFORM send_due_reminders();
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notification_deliveries WHERE recipient_id = v_owing),
    1, 'running the sweep again the same day does not send a second message');

  -- The member who opted out stays out of it even when they owe money.
  v_fee := tests.give_fee(v_quiet, (date_trunc('month', today_eat()) - INTERVAL '1 month')::date);
  PERFORM send_due_reminders();
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notification_deliveries WHERE recipient_id = v_quiet),
    0, 'the sweep respects the opt-out');

  -- ==================================================== health (032)
  -- The signal that would have caught a queue nobody was draining.
  SELECT * INTO v_health FROM v_notification_health;
  PERFORM tests.eq(v_health.queued, 1, 'the queue depth is reported');
  PERFORM tests.eq(v_health.stuck,  0, 'a fresh row is not stuck');

  UPDATE notification_deliveries SET created_at = now() - interval '3 hours';
  SELECT * INTO v_health FROM v_notification_health;
  PERFORM tests.eq(v_health.stuck, 1, 'a row queued for hours means the drain is not running');

  -- ==================================================== health names the real cause (038)
  -- The banner reads last_error aloud to an admin, so a stale reason is worse
  -- than no reason: it describes a batch that is already retired as though it
  -- were the live fault, and the honest reading of it is "nothing to do".
  PERFORM tests.eq(v_health.last_error, NULL::text,
    'a queue nothing has attempted reports no reason, because there is none');
  PERFORM tests.eq(v_health.never_sent::text, 'true',
    'never_sent marks a drain that has delivered nothing, ever');

  -- Exactly the row 032's backfill leaves behind. However recent it is, it is
  -- retired by design and is not why the queue is stuck now.
  UPDATE notification_deliveries
     SET status = 'skipped',
         last_error = 'expired unsent — queued before dispatch was connected';
  SELECT * INTO v_health FROM v_notification_health;
  PERFORM tests.eq(v_health.last_error, NULL::text,
    'a skipped row never becomes the reported cause');

  -- A blocked batch is different: the dispatcher leaves the reason on a row it
  -- deliberately keeps queued, so queued rows must stay in scope.
  UPDATE notification_deliveries
     SET status = 'queued',
         last_error = 'Beem: insufficient balance — top up to resume reminders';
  SELECT * INTO v_health FROM v_notification_health;
  PERFORM tests.eq(v_health.last_error,
    'Beem: insufficient balance — top up to resume reminders',
    'a blocking reason on a queued row is what the admin is shown');

  -- One success is the whole difference between "never connected" and "stopped".
  UPDATE notification_deliveries
     SET status = 'sent', sent_at = now(), last_error = NULL;
  SELECT * INTO v_health FROM v_notification_health;
  PERFORM tests.eq(v_health.never_sent::text, 'false',
    'a single delivery proves the drain was connected at least once');

  -- ==================================================== the drain job guard
  -- Scheduling without a secret would only ever collect 503s from an endpoint
  -- that fails closed, so it is refused outright.
  PERFORM tests.raises(
    $q$ SELECT schedule_notification_drain('https://x.functions.supabase.co/f', '') $q$,
    'a drain job cannot be scheduled without a dispatch secret');
  PERFORM tests.raises(
    $q$ SELECT schedule_notification_drain('', 'secret') $q$,
    'nor without a URL');

  -- 039. The scheduled command is `select net.http_post(...)`, so without pg_net
  -- the job fails every fifteen minutes inside pg_cron where nobody sees it,
  -- while the queue fills. This harness is plain Postgres with no pg_net, which
  -- is exactly the condition being asserted.
  PERFORM tests.raises(
    $q$ SELECT schedule_notification_drain('https://x.functions.supabase.co/f', 'secret') $q$,
    'a drain job is refused when pg_net is missing, rather than scheduled and left to fail unseen');

  -- ==================================================== Swahili (033)
  -- The group reads Swahili and preferred_language has defaulted to 'sw' since
  -- 026, so the DEFAULT path must produce Swahili, not English.
  DELETE FROM notification_deliveries;
  PERFORM tests.eq(member_lang(v_owing), 'sw', 'members default to Swahili');

  -- Money and dates must match how the app renders them ("TSh 10,000").
  PERFORM tests.eq(fmt_tzs(10000),   'TSh 10,000', 'money is formatted like the app');
  PERFORM tests.eq(fmt_tzs(1234567), 'TSh 1,234,567', 'thousands separators');
  PERFORM tests.eq(fmt_tzs(0),       'TSh 0', 'zero still renders');
  PERFORM tests.eq(fmt_day('2026-08-31'::date), '31/08/2026', 'dates are unambiguous');

  -- The reminder sweep, in Swahili, with no stray raw numerics.
  PERFORM send_due_reminders();
  PERFORM tests.eq(
    (SELECT title FROM notification_deliveries WHERE recipient_id = v_owing),
    'Ada ya mwezi imechelewa', 'an overdue fee is announced in Swahili');
  IF (SELECT body FROM notification_deliveries WHERE recipient_id = v_owing)
       NOT LIKE '%TSh%' THEN
    RAISE EXCEPTION 'the reminder body does not carry a formatted amount';
  END IF;
  IF (SELECT body FROM notification_deliveries WHERE recipient_id = v_owing)
       LIKE '%.00%' THEN
    RAISE EXCEPTION 'a raw numeric leaked into an SMS body';
  END IF;

  -- A member who has chosen English still gets English.
  DELETE FROM notification_deliveries;
  UPDATE profiles SET preferred_language = 'en' WHERE id = v_owing;
  PERFORM send_due_reminders();
  PERFORM tests.eq(
    (SELECT title FROM notification_deliveries WHERE recipient_id = v_owing),
    'Monthly fee overdue', 'English is honoured when the member asks for it');
  UPDATE profiles SET preferred_language = 'sw' WHERE id = v_owing;

  -- The BEFORE INSERT trigger translates event notifications, and 026's fan-out
  -- (an AFTER INSERT) must therefore carry the Swahili into the outbox.
  DELETE FROM notification_deliveries;
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_owing, 'submission_approved', 'Payment approved',
          'Your monthly fee was approved.', jsonb_build_object('amount', 10000));
  PERFORM tests.eq(
    (SELECT title FROM notifications
      WHERE recipient_id = v_owing AND kind = 'submission_approved'),
    'Malipo yamethibitishwa', 'the stored notification is translated in place');
  PERFORM tests.eq(
    (SELECT body FROM notifications
      WHERE recipient_id = v_owing AND kind = 'submission_approved'),
    'Malipo yako ya TSh 10,000 yamethibitishwa.', 'and the amount is interpolated');
  PERFORM tests.eq(
    (SELECT title FROM notification_deliveries WHERE recipient_id = v_owing),
    'Malipo yamethibitishwa', 'the SMS inherits the translation from the fan-out');

  -- A NULL template body keeps free text an admin typed — translating the label
  -- must not throw away their words.
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_owing, 'submission_rejected', 'Payment rejected',
          'Risiti haisomeki', jsonb_build_object('submission_id', gen_random_uuid()));
  PERFORM tests.eq(
    (SELECT title FROM notifications
      WHERE recipient_id = v_owing AND kind = 'submission_rejected'),
    'Malipo yamekataliwa', 'the label is translated');
  PERFORM tests.eq(
    (SELECT body FROM notifications
      WHERE recipient_id = v_owing AND kind = 'submission_rejected'),
    'Risiti haisomeki', 'the admin''s own words are left alone');

  -- {member} resolves an id to a name.
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_admin, 'new_loan', 'New loan request', 'Someone requested a loan',
          jsonb_build_object('member_id', v_owing));
  PERFORM tests.eq(
    (SELECT body FROM notifications WHERE recipient_id = v_admin AND kind = 'new_loan'),
    'Notify Owing ameomba mkopo.', 'a member id renders as their name');

  -- An unknown kind is delivered exactly as composed rather than mangled.
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_owing, 'some_future_kind', 'Brand new thing', 'Body text', NULL);
  PERFORM tests.eq(
    (SELECT title FROM notifications
      WHERE recipient_id = v_owing AND kind = 'some_future_kind'),
    'Brand new thing', 'a kind with no template falls back to English');

  DELETE FROM notification_deliveries;
  DELETE FROM notifications;
  PERFORM send_due_reminders();

  -- ==================================================== members cannot read the outbox
  -- It is a list of everybody's phone numbers.
  PERFORM tests.as_user(v_quiet);
  PERFORM tests.eq(
    (SELECT count(*)::numeric FROM notification_deliveries WHERE recipient_id <> v_quiet),
    0, 'a member cannot read another member''s deliveries');
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_admin);
  IF (SELECT count(*) FROM notification_deliveries) = 0 THEN
    RAISE EXCEPTION 'an admin cannot see the outbox — they cannot diagnose a stuck queue';
  END IF;
  PERFORM tests.as_owner();
END;
$$;
