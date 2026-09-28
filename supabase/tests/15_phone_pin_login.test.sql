-- 15_phone_pin_login.test.sql — phone + PIN login (042).
--
-- The PIN itself is hashed and compared in the member-pin-auth Edge Function, so
-- what is testable here is everything the Edge Function stands on: that a number
-- typed three different ways resolves to one member, that a second member cannot
-- take a number that is already in use, that the attempt limiter actually locks,
-- and — most importantly — that none of the PIN machinery is reachable by a
-- member's own JWT. That last group is the reason this file exists: the tables
-- are protected by having no RLS policies at all rather than by a restrictive
-- one, which is correct but is the kind of thing a later migration can undo by
-- accident with a single blanket GRANT.
--
-- The function-privilege assertions below are not theoretical. On their first
-- run lookup_phone_login WAS callable by a member, because 042 revoked only the
-- PUBLIC grant and Supabase hands anon and authenticated an explicit one
-- through ALTER DEFAULT PRIVILEGES.

DO $$
DECLARE
  v_admin   uuid;
  v_jane    uuid;
  v_juma    uuid;
  v_locked  timestamptz;
  v_i       int;
BEGIN
  v_admin := tests.make_admin('Pin Admin');
  v_jane  := tests.make_member('Jane Mushi');
  v_juma  := tests.make_member('Juma Kileo');

  -- =================================================== normalisation
  -- The three forms an admin actually types for one handset.
  PERFORM tests.eq(normalize_phone_tz('+255712345678'), '712345678',
    'the +255 form normalises to the subscriber number');
  PERFORM tests.eq(normalize_phone_tz('255712345678'), '712345678',
    'the bare 255 form normalises to the same');
  PERFORM tests.eq(normalize_phone_tz('0712345678'), '712345678',
    'the leading-zero form normalises to the same');
  PERFORM tests.eq(normalize_phone_tz('712345678'), '712345678',
    'an already-canonical number is unchanged');

  -- Punctuation and spacing are noise, not identity.
  PERFORM tests.eq(normalize_phone_tz('+255 712 345 678'), '712345678',
    'spaces are ignored');
  PERFORM tests.eq(normalize_phone_tz('0712-345-678'), '712345678',
    'dashes are ignored');

  PERFORM tests.eq(coalesce(normalize_phone_tz(NULL), 'NULL'), 'NULL',
    'no phone number normalises to NULL');
  PERFORM tests.eq(coalesce(normalize_phone_tz('   '), 'NULL'), 'NULL',
    'a blank phone number normalises to NULL');

  -- Two different handsets must not collide.
  PERFORM tests.eq(
    (normalize_phone_tz('0712345678') = normalize_phone_tz('0713345678'))::text,
    'false', 'different numbers stay different');

  -- =================================================== first name
  PERFORM tests.eq(member_first_name('Jane Mushi'), 'jane',
    'the first word of a full name, lowercased');
  PERFORM tests.eq(member_first_name('JANE MUSHI'), 'jane',
    'case does not matter');
  PERFORM tests.eq(member_first_name('  Jane   Mushi '), 'jane',
    'surrounding whitespace does not matter');
  PERFORM tests.eq(member_first_name('Mwalimu'), 'mwalimu',
    'a single-word name is its own first name');

  -- =================================================== phone uniqueness
  -- Phone number is half the login credential, so it has to point at one member.
  -- 001 already had a UNIQUE on the raw column; what 042 adds is that the three
  -- spellings of one number count as the same number.
  UPDATE profiles SET phone_number = '+255712345678' WHERE id = v_jane;

  PERFORM tests.raises(
    format('UPDATE profiles SET phone_number = %L WHERE id = %L', '0712345678', v_juma),
    'a second member cannot take the same number written another way');

  PERFORM tests.raises(
    format('UPDATE profiles SET phone_number = %L WHERE id = %L', '255712345678', v_juma),
    'nor written as 255…');

  -- A genuinely different number is fine.
  UPDATE profiles SET phone_number = '0713999888' WHERE id = v_juma;
  PERFORM tests.eq(
    (SELECT normalize_phone_tz(phone_number) FROM profiles WHERE id = v_juma),
    '713999888', 'a different number is accepted');

  -- Two members with no number at all do not collide — the index is partial.
  UPDATE profiles SET phone_number = NULL WHERE id = v_admin;
  PERFORM tests.eq(
    (SELECT count(*)::text FROM profiles WHERE phone_number IS NULL AND id = v_admin),
    '1', 'a profile may still have no phone number');

  -- =================================================== the lookup
  PERFORM tests.eq(
    (SELECT member_id FROM lookup_phone_login('0712345678'))::text,
    v_jane::text, 'the lookup finds the member whichever form is typed');
  PERFORM tests.eq(
    (SELECT first_name FROM lookup_phone_login('+255712345678')),
    'jane', 'and returns the first name to check against');
  PERFORM tests.eq(
    (SELECT count(*)::text FROM lookup_phone_login('0755000111')),
    '0', 'a number belonging to nobody returns no row');

  -- No PIN set yet, so the hash is NULL. The Edge Function must treat that as a
  -- failed verification, not as a member who can sign in with anything.
  PERFORM tests.eq(
    (SELECT coalesce(pin_hash, 'NULL') FROM lookup_phone_login('0712345678')),
    'NULL', 'a member with no PIN has no hash to match');

  -- =================================================== the attempt limiter
  -- Five attempts are verified; the sixth is refused. Off-by-one matters here:
  -- locking at the fifth would silently give a member four tries, not five.
  FOR v_i IN 1..5 LOOP
    v_locked := begin_login_attempt('712345678');
    IF v_locked IS NOT NULL THEN
      RAISE EXCEPTION 'attempt % was refused, but the first 5 must be allowed', v_i;
    END IF;
  END LOOP;

  v_locked := begin_login_attempt('712345678');
  PERFORM tests.eq((v_locked IS NOT NULL)::text, 'true',
    'the sixth attempt in a row is locked out');
  PERFORM tests.eq((v_locked > now())::text, 'true',
    'and the lock is in the future');

  -- Still locked while it stands.
  PERFORM tests.eq((begin_login_attempt('712345678') IS NOT NULL)::text, 'true',
    'a locked number stays locked');

  -- A correct PIN clears it, which is what the Edge Function calls on success.
  PERFORM clear_login_attempts('712345678');
  PERFORM tests.eq(
    (SELECT count(*)::text FROM phone_login_attempts WHERE phone_key = '712345678'),
    '0', 'clearing removes the row entirely');
  PERFORM tests.eq((begin_login_attempt('712345678') IS NULL)::text, 'true',
    'and the next attempt is allowed again');

  -- The limiter is keyed on the TYPED number, not on a member, so a number that
  -- matches nobody throttles identically. Without this the endpoint would answer
  -- "is this number in the group?" by which message came back.
  FOR v_i IN 1..6 LOOP
    v_locked := begin_login_attempt('755000111');
  END LOOP;
  PERFORM tests.eq((v_locked IS NOT NULL)::text, 'true',
    'a number belonging to nobody locks out the same way');

  -- An expired lock does not strand the member forever.
  UPDATE phone_login_attempts
     SET locked_until = now() - interval '1 minute'
   WHERE phone_key = '755000111';
  PERFORM tests.eq((begin_login_attempt('755000111') IS NULL)::text, 'true',
    'an expired lock lets the next attempt through');
  PERFORM tests.eq(
    (SELECT attempts::text FROM phone_login_attempts WHERE phone_key = '755000111'),
    '1', 'and the count starts over rather than re-locking immediately');

  -- A quiet spell also resets the count, so a member who mistypes once a month
  -- does not accumulate toward a lockout over a year.
  UPDATE phone_login_attempts
     SET attempts = 4, first_attempt_at = now() - interval '2 hours',
         locked_until = NULL
   WHERE phone_key = '755000111';
  PERFORM tests.eq((begin_login_attempt('755000111') IS NULL)::text, 'true',
    'an attempt after the window is allowed');
  PERFORM tests.eq(
    (SELECT attempts::text FROM phone_login_attempts WHERE phone_key = '755000111'),
    '1', 'and the stale count is discarded');
END $$;

-- ===========================================================================
-- Nothing above ran as a member. This half does, and it is the part that
-- matters: member_pins holds the group's credentials, and it is protected by
-- having no RLS policy rather than by a restrictive one.
-- ===========================================================================
DO $$
DECLARE
  v_admin uuid;
  v_jane  uuid;
  v_juma  uuid;
BEGIN
  -- as_user() is SET LOCAL ROLE and the whole FILE is one transaction, so a previous
  -- block that ended mid-impersonation would leave this one as `authenticated` —
  -- where 034 has revoked UPDATE on profiles and the fixtures below would fail on
  -- permissions rather than on anything this file is testing.
  PERFORM tests.as_owner();

  v_admin := tests.make_admin('Lockdown Admin');
  v_jane  := tests.make_member('Locked Jane');
  v_juma  := tests.make_member('Nosy Juma');

  UPDATE profiles SET phone_number = '0714111222' WHERE id = v_jane;

  INSERT INTO member_pins (member_id, pin_hash, must_change)
  VALUES (v_jane, 'pbkdf2_sha256$1$c2FsdA==$aGFzaA==', true);

  PERFORM tests.as_user(v_juma);

  -- A member cannot read anyone's PIN hash, including their own. There is no
  -- reason for a browser session to hold it, and a SELECT that works for "own
  -- row" is one policy change away from working for every row.
  PERFORM tests.raises(
    'SELECT pin_hash FROM member_pins',
    'a member cannot read the PIN table at all');
  PERFORM tests.raises(
    format('SELECT pin_hash FROM member_pins WHERE member_id = %L', v_juma),
    'not even scoped to their own row');
  PERFORM tests.raises(
    format('UPDATE member_pins SET pin_hash = %L WHERE member_id = %L', 'x', v_jane),
    'and certainly cannot overwrite another member''s PIN');
  PERFORM tests.raises(
    format('INSERT INTO member_pins (member_id, pin_hash) VALUES (%L, %L)', v_juma, 'x'),
    'nor set one directly, bypassing the PIN rules');

  -- The attempt counter is not a member's to read or clear either — clearing it
  -- would hand back unlimited guesses.
  PERFORM tests.raises(
    'SELECT * FROM phone_login_attempts',
    'a member cannot read the attempt counter');
  PERFORM tests.raises(
    'DELETE FROM phone_login_attempts',
    'nor wipe it to reset their own lockout');

  -- The service-role helpers must not be reachable with a member's JWT.
  -- lookup_phone_login would be a phone-number-to-member directory, and
  -- clear_login_attempts would defeat the lockout outright.
  PERFORM tests.raises(
    'SELECT * FROM lookup_phone_login(''0714111222'')',
    'a member cannot call the login lookup');
  PERFORM tests.raises(
    'SELECT begin_login_attempt(''714111222'')',
    'a member cannot spend attempts on someone else''s number');
  PERFORM tests.raises(
    'SELECT clear_login_attempts(''714111222'')',
    'a member cannot clear the attempt counter');
  PERFORM tests.raises(
    'SELECT phone_number_taken(''0714111222'')',
    'a member cannot probe which numbers are registered');

  -- What a member IS allowed: their own PIN status, and nobody else's. The
  -- function takes no argument precisely so there is nothing to point elsewhere.
  PERFORM tests.eq(
    (SELECT has_pin::text FROM own_pin_status()),
    'false', 'a member with no PIN is told so');

  PERFORM tests.as_user(v_jane);
  PERFORM tests.eq(
    (SELECT has_pin::text FROM own_pin_status()),
    'true', 'a member with a PIN is told so');
  PERFORM tests.eq(
    (SELECT must_change::text FROM own_pin_status()),
    'true', 'and that it is one the admin set');

  -- member_pin_overview is the admin's recovery screen and gates on is_admin()
  -- inside the function body, so a member gets an empty result rather than an
  -- error — it must not leak who has a PIN and who is locked out.
  PERFORM tests.as_user(v_juma);
  PERFORM tests.eq(
    (SELECT count(*)::text FROM member_pin_overview()),
    '0', 'a member sees nothing in the admin PIN overview');

  PERFORM tests.as_user(v_admin);
  PERFORM tests.eq(
    (SELECT (count(*) > 0)::text FROM member_pin_overview()),
    'true', 'an admin sees the overview');
  PERFORM tests.eq(
    (SELECT has_pin::text FROM member_pin_overview() WHERE member_id = v_jane),
    'true', 'and it reports who has a PIN');

  -- No hash column on the overview at all: an admin resets a PIN, never reads one.
  PERFORM tests.raises(
    'SELECT pin_hash FROM member_pin_overview()',
    'the admin overview does not expose the hash');
END $$;

-- ===========================================================================
-- update_own_phone(): a member changing half of their own login credential.
-- ===========================================================================
DO $$
DECLARE
  v_jane uuid;
  v_juma uuid;
BEGIN
  -- Previous block ended as the admin. Back to the owner to build fixtures.
  PERFORM tests.as_owner();

  v_jane := tests.make_member('Phone Jane');
  v_juma := tests.make_member('Phone Juma');

  UPDATE profiles SET phone_number = '0715222333' WHERE id = v_jane;

  PERFORM tests.as_user(v_juma);

  -- The happy path still works, which 006 is what it is for.
  PERFORM update_own_phone('0716333444');
  PERFORM tests.eq(
    (SELECT phone_number FROM profiles WHERE id = v_juma),
    '0716333444', 'a member can still set their own phone number');

  -- Whitespace is trimmed, as before.
  PERFORM update_own_phone('  0716333555  ');
  PERFORM tests.eq(
    (SELECT phone_number FROM profiles WHERE id = v_juma),
    '0716333555', 'the stored number is trimmed');

  -- Taking another member's number in a different spelling is refused. Before
  -- 042 this was possible, and it would have pointed one credential at two
  -- members.
  PERFORM tests.raises(
    'SELECT update_own_phone(''+255715222333'')',
    'a member cannot take another member''s number in another form');

  PERFORM tests.eq(
    (SELECT phone_number FROM profiles WHERE id = v_juma),
    '0716333555', 'and the refused change did not land');

  -- Clearing the number would cost them their login, so it is refused rather
  -- than silently accepted from an empty field.
  PERFORM tests.raises(
    'SELECT update_own_phone('''')',
    'a member cannot blank their phone number');
  PERFORM tests.raises(
    'SELECT update_own_phone(''   '')',
    'nor blank it with whitespace');

  -- Still theirs alone: the function writes to auth.uid() and takes no id.
  --
  -- Read as the owner, not as Juma. RLS on `profiles` does not let one member SELECT
  -- another's row at all — that is why 019 exposes the member list through the
  -- SECURITY DEFINER group_member_directory() instead — so asking as Juma returns no
  -- row, and the assertion would pass or fail for the wrong reason.
  PERFORM tests.as_owner();
  PERFORM tests.eq(
    (SELECT phone_number FROM profiles WHERE id = v_jane),
    '0715222333', 'another member''s number is untouched throughout');
END $$;
