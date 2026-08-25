-- 033_swahili_messages.sql — the group reads Swahili; the messages were English.
--
-- `profiles.preferred_language` has defaulted to 'sw' since 026 and nothing ever
-- read it. Every notification title and body is composed in English in SQL, across
-- 29 INSERT sites in 11 migrations — and both channels show it raw:
-- NotificationsBell renders `{n.title}` with no t(), and the SMS dispatcher sends
-- whatever the outbox holds.
--
-- WHERE TO TRANSLATE. Not at the 29 call sites: most sit inside money-path
-- triggers and RPCs that have no business knowing about language, and editing them
-- would put the payment waterfall back in the blast radius of a copy change.
--
-- Instead, one BEFORE INSERT trigger on `notifications` rewrites the row into the
-- recipient's language. It lands before 026's AFTER INSERT fan-out, so the outbox
-- inherits the translation for free — the SMS and the in-app bell both change, and
-- not one existing trigger is touched.
--
-- `send_due_reminders` is the exception: it calls enqueue_delivery directly and
-- never writes a `notifications` row, so it is translated in place. It is also the
-- one that sends every single day, which makes it the one that matters most.
--
-- FALLBACK IS ENGLISH. No template for a kind, or a member who has chosen 'en',
-- means the message is delivered exactly as it is composed today. Nothing breaks
-- on a kind added later; it simply stays English until it gets a template.
--
-- Requires 026.

-- --------------------------------------------------------------------------
-- 1. Formatting helpers.
--
--    The app renders money through Intl 'sw-TZ' as "TSh 10,000". SQL was emitting
--    raw numerics — "10000.00 TZS" — so the same fee appeared two different ways
--    depending on whether you read it in the app or in a text message.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fmt_tzs(p_amount numeric)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'TSh ' || to_char(round(COALESCE(p_amount, 0)), 'FM999,999,999,990');
$$;

-- Dates in an SMS: unambiguous and short. "31/08/2026", not "2026-08-31".
CREATE OR REPLACE FUNCTION fmt_day(p_date date)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE WHEN p_date IS NULL THEN '' ELSE to_char(p_date, 'DD/MM/YYYY') END;
$$;

CREATE OR REPLACE FUNCTION member_lang(p_member uuid)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(NULLIF(trim(preferred_language), ''), 'sw')
    FROM profiles WHERE id = p_member;
$$;

-- --------------------------------------------------------------------------
-- 2. The phrase book.
--
--    Keyed on `notifications.kind`, which is already a stable machine key at
--    every one of the 29 call sites — no new vocabulary to invent.
--
--    body = NULL means "keep whatever was composed". That is the honest answer
--    for the messages whose body IS free text an admin typed (a rejection
--    reason): translating the label while leaving their words alone.
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS notification_templates (
  kind  text NOT NULL,
  lang  text NOT NULL DEFAULT 'sw',
  title text NOT NULL,
  body  text,
  PRIMARY KEY (kind, lang)
);

ALTER TABLE notification_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone signed in reads templates" ON notification_templates;
CREATE POLICY "Anyone signed in reads templates" ON notification_templates
  FOR SELECT USING (auth.uid() IS NOT NULL);

GRANT SELECT ON notification_templates TO authenticated;

-- Placeholders are filled from the notification's own `data` payload. Only keys
-- that are actually present at the call site are used — a placeholder with no
-- matching key would render as literal braces, so each template below was written
-- against the jsonb_build_object() call that feeds it.
INSERT INTO notification_templates (kind, lang, title, body) VALUES
  -- Payments (009)
  ('submission_approved', 'sw', 'Malipo yamethibitishwa',
   'Malipo yako ya {amount} yamethibitishwa.'),
  ('submission_rejected', 'sw', 'Malipo yamekataliwa', NULL),

  -- Loans (009)
  ('loan_active',   'sw', 'Mkopo umeidhinishwa',
   'Mkopo wako umetolewa. Ratiba ya marejesho ipo kwenye programu yako.'),
  ('loan_rejected', 'sw', 'Ombi la mkopo limekataliwa', NULL),
  ('loan_closed',   'sw', 'Mkopo umelipwa wote',
   'Hongera — mkopo wako umelipwa wote.'),

  -- Loan distress (022)
  ('loan_restructure',          'sw', 'Mkopo wako umepangwa upya', NULL),
  ('loan_write_off',            'sw', 'Mkopo wako umefutwa', NULL),
  ('loan_recover_from_savings', 'sw', 'Mkopo umelipwa kutoka akiba yako',
   'Sehemu ya akiba yako imetumika kulipa deni la mkopo wako.'),

  -- Withdrawals and exit (025)
  ('withdrawal_approved', 'sw', 'Ombi la kutoa fedha limeidhinishwa',
   'Ombi lako la kutoa fedha limeidhinishwa na utalipwa.'),
  ('withdrawal_rejected', 'sw', 'Ombi la kutoa fedha limekataliwa', NULL),
  ('withdrawal_paid',     'sw', 'Fedha zimelipwa',
   'Fedha ulizoomba zimelipwa kwako.'),

  -- Share-out (024)
  ('share_out_ready', 'sw', 'Mgao wako uko tayari',
   'Mzunguko umefungwa. Angalia mgao wako kwenye programu.'),
  ('share_out_paid',  'sw', 'Mgao umelipwa',
   'Mgao wako umelipwa kwako.'),

  -- Guarantors (028)
  ('guarantee_requested', 'sw', 'Umeombwa kudhamini mkopo',
   'Mwanachama amekuomba udhamini mkopo wake. Fungua programu ili kujibu.'),
  ('guarantee_accepted',  'sw', 'Dhamana imekubaliwa',
   'Mwanachama amekubali kudhamini mkopo wako.'),
  ('guarantee_declined',  'sw', 'Dhamana imekataliwa',
   'Mwanachama amekataa kudhamini mkopo wako.'),
  ('guarantee_called',    'sw', 'Dhamana yako imetumika',
   'Kiasi kimetolewa kwenye akiba yako kulipia mkopo uliodhamini.'),

  -- Savings edits (013)
  ('savings_edited', 'sw', 'Akiba yako imerekebishwa',
   'Marekebisho ya {delta} yamefanywa kwenye akiba yako.'),

  -- Meetings and social fund (030)
  ('attendance_fine',       'sw', 'Faini ya mahudhurio',
   'Faini imetolewa kwenye akiba yako kwa mkutano wa kikundi.'),
  ('social_grant_approved', 'sw', 'Msaada wa mfuko wa jamii umeidhinishwa',
   'Umepewa msaada kutoka kwenye mfuko wa jamii.'),

  -- Group rules (020) — every active member gets this one.
  ('setting_changed', 'sw', 'Sheria ya kikundi imebadilika', NULL),

  -- Admin queue (009, 013, 015, 022, 024, 025, 030). Admins are members of the
  -- same group and read the same language.
  ('new_submission',           'sw', 'Malipo mapya ya kukagua',
   '{member} amewasilisha malipo yanayosubiri kukaguliwa.'),
  ('new_loan',                 'sw', 'Ombi jipya la mkopo',
   '{member} ameomba mkopo.'),
  ('savings_edit_requested',   'sw', 'Marekebisho ya akiba yameombwa', NULL),
  ('pool_edit_requested',      'sw', 'Marekebisho ya mfuko yameombwa', NULL),
  ('setting_change_requested', 'sw', 'Mabadiliko ya sheria yamependekezwa', NULL),
  ('loan_action_requested',    'sw', 'Hatua ya mkopo imependekezwa', NULL),
  ('cycle_close_requested',    'sw', 'Kufunga mzunguko kumependekezwa', NULL),
  ('withdrawal_requested',     'sw', 'Ombi la kutoa fedha', NULL),
  ('member_exit_requested',    'sw', 'Kuondoka kwa mwanachama kumependekezwa', NULL),
  ('deletion_requested',       'sw', 'Kufuta mwanachama kumeombwa', NULL),
  ('social_grant_requested',   'sw', 'Msaada wa mfuko wa jamii umependekezwa', NULL)
ON CONFLICT (kind, lang) DO UPDATE
  SET title = EXCLUDED.title, body = EXCLUDED.body;

-- `role_changed` is deliberately absent: its title depends on promote-vs-revoke,
-- which `kind` alone cannot distinguish. It falls back to English rather than
-- telling a member the wrong thing about their own role.

-- --------------------------------------------------------------------------
-- 3. Rendering.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION render_template(p_text text, p_data jsonb)
RETURNS text AS $$
DECLARE
  v_out text := p_text;
  v_key text;
  v_val text;
BEGIN
  IF v_out IS NULL OR p_data IS NULL THEN RETURN v_out; END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_data) LOOP
    v_val := p_data ->> v_key;
    -- Money keys are formatted the way the app formats money; everything else is
    -- substituted verbatim.
    IF v_key IN ('amount', 'principal', 'delta', 'fine', 'settlement')
       AND v_val ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
      v_val := fmt_tzs(v_val::numeric);
    END IF;
    v_out := replace(v_out, '{' || v_key || '}', COALESCE(v_val, ''));
  END LOOP;

  -- {member} is a name, and the payloads carry an id rather than the name.
  IF v_out LIKE '%{member}%' THEN
    v_val := COALESCE(p_data ->> 'member_id', p_data ->> 'target_id');
    IF v_val ~* '^[0-9a-f-]{36}$' THEN
      SELECT full_name INTO v_val FROM profiles WHERE id = v_val::uuid;
    ELSE
      v_val := NULL;
    END IF;
    v_out := replace(v_out, '{member}', COALESCE(v_val, 'Mwanachama'));
  END IF;

  RETURN v_out;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

-- BEFORE INSERT, so 026's AFTER INSERT fan-out copies the translated text into
-- the outbox and the SMS goes out in the member's language with no further work.
CREATE OR REPLACE FUNCTION translate_notification()
RETURNS trigger AS $$
DECLARE
  v_lang text;
  v_tpl  notification_templates%ROWTYPE;
BEGIN
  v_lang := member_lang(NEW.recipient_id);
  IF v_lang IS NULL OR v_lang = 'en' THEN RETURN NEW; END IF;

  SELECT * INTO v_tpl
    FROM notification_templates
   WHERE kind = NEW.kind AND lang = v_lang;

  -- No phrase for this kind: leave it exactly as composed.
  IF v_tpl.kind IS NULL THEN RETURN NEW; END IF;

  NEW.title := render_template(v_tpl.title, NEW.data);
  -- A NULL template body means the original body is free text worth keeping.
  IF v_tpl.body IS NOT NULL THEN
    NEW.body := render_template(v_tpl.body, NEW.data);
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS on_notification_translate ON notifications;
CREATE TRIGGER on_notification_translate
  BEFORE INSERT ON notifications
  FOR EACH ROW EXECUTE FUNCTION translate_notification();

-- --------------------------------------------------------------------------
-- 4. The daily reminders.
--
--    These never write a `notifications` row — they call enqueue_delivery
--    directly — so the trigger above cannot reach them. They are also the only
--    messages that go out every single day, so they are translated per member
--    rather than in bulk.
--
--    Same structure as 026: due within 3 days or already overdue, deduped per
--    obligation per ISO week so an overdue member is nudged weekly, not daily.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION send_due_reminders()
RETURNS int AS $$
DECLARE
  r      record;
  v_week text := to_char(today_eat(), 'IYYY-IW');
  v_n    int := 0;
  v_lang text;
  v_title text;
  v_body  text;
BEGIN
  -- Monthly fees: due soon, or already overdue.
  FOR r IN
    SELECT f.member_id, f.id, f.due_date, f.total_with_penalty, f.computed_status
      FROM v_fee_status_money f
     WHERE f.computed_status <> 'paid'
       AND f.remaining > 0
       AND f.due_date <= today_eat() + 3
  LOOP
    v_lang := member_lang(r.member_id);

    IF v_lang = 'en' THEN
      v_title := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Monthly fee overdue' ELSE 'Monthly fee due soon' END;
      v_body  := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Your monthly fee of ' || fmt_tzs(r.total_with_penalty) ||
                           ' is overdue. Pay in the app to stop the penalty growing.'
                      ELSE 'Your monthly fee of ' || fmt_tzs(r.total_with_penalty) ||
                           ' is due on ' || fmt_day(r.due_date) || '.' END;
    ELSE
      v_title := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Ada ya mwezi imechelewa'
                      ELSE 'Ada ya mwezi inakaribia kuisha muda' END;
      v_body  := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Ada yako ya mwezi ya ' || fmt_tzs(r.total_with_penalty) ||
                           ' imechelewa. Lipa kwenye programu ili faini isiongezeke.'
                      ELSE 'Ada yako ya mwezi ya ' || fmt_tzs(r.total_with_penalty) ||
                           ' inatakiwa kulipwa tarehe ' || fmt_day(r.due_date) || '.' END;
    END IF;

    PERFORM enqueue_delivery(r.member_id, v_title, v_body, NULL,
                             'fee:' || r.id || ':' || v_week);
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
    v_lang := member_lang(r.member_id);

    IF v_lang = 'en' THEN
      v_title := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Loan repayment overdue' ELSE 'Loan repayment due soon' END;
      v_body  := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Your loan repayment of ' || fmt_tzs(r.total_with_penalty) ||
                           ' is overdue. Pay in the app to stop the penalty growing.'
                      ELSE 'Your loan repayment of ' || fmt_tzs(r.total_with_penalty) ||
                           ' is due on ' || fmt_day(r.due_date) || '.' END;
    ELSE
      v_title := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Marejesho ya mkopo yamechelewa'
                      ELSE 'Marejesho ya mkopo yanakaribia' END;
      v_body  := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Marejesho yako ya mkopo ya ' || fmt_tzs(r.total_with_penalty) ||
                           ' yamechelewa. Lipa kwenye programu ili faini isiongezeke.'
                      ELSE 'Marejesho yako ya mkopo ya ' || fmt_tzs(r.total_with_penalty) ||
                           ' yanatakiwa kulipwa tarehe ' || fmt_day(r.due_date) || '.' END;
    END IF;

    PERFORM enqueue_delivery(r.member_id, v_title, v_body, NULL,
                             'inst:' || r.id || ':' || v_week);
    v_n := v_n + 1;
  END LOOP;

  -- Share-outs waiting to be collected.
  FOR r IN
    SELECT d.member_id, d.id, d.total_payout_tzs
      FROM distributions d
     WHERE d.status = 'pending'
  LOOP
    v_lang := member_lang(r.member_id);

    IF v_lang = 'en' THEN
      v_title := 'Your share-out is waiting';
      v_body  := fmt_tzs(r.total_payout_tzs) || ' is ready for you from the last cycle.';
    ELSE
      v_title := 'Mgao wako unakusubiri';
      v_body  := fmt_tzs(r.total_payout_tzs) || ' iko tayari kwako kutoka mzunguko uliopita.';
    END IF;

    PERFORM enqueue_delivery(r.member_id, v_title, v_body, NULL,
                             'dist:' || r.id || ':' || v_week);
    v_n := v_n + 1;
  END LOOP;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (NULL, 'send_due_reminders', 'system', NULL,
          jsonb_build_object('reminders', v_n, 'week', v_week));

  RETURN v_n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
