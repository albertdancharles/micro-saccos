-- 042_phone_pin_login.sql — let a member sign in with first name + phone + PIN.
--
-- Members have never had a real email. The admin mints a synthetic
-- firstname.lastname@umojagroup.app address (AddMemberModal) and reads out a
-- 10-character temp password, and the member is then expected to remember both.
-- In practice they remember neither, so every lost login becomes an admin reset.
--
-- This migration adds the storage behind a login that asks for what a member
-- actually knows: their first name, their phone number, and a PIN they chose.
--
-- The one thing it deliberately does NOT do is make name + phone sufficient on
-- their own. Every member of a 15-person group knows every other member's first
-- name and phone number, and full_name is already published in-app by
-- group_member_directory() (019), so with no secret the group's own phone list
-- is a working credential for every account in it.
--
-- Being precise about what that costs, because 034 already took the obvious
-- answer away: a member cannot file a loan or a payment, since those INSERT
-- policies are gone, so the risk is not forged requests. It is three other
-- things. Reading another member's dashboard and the PII on their profile
-- (national ID, next of kin, residence). Changing their phone number through
-- update_own_phone(), which after this migration IS half their login, locking
-- them out of their own account. And signing in as an ADMIN, which is the one
-- that matters: an admin records payments and approves loans, and since 041 an
-- overseer's single signature is a quorum, so one impersonated admin session
-- moves group money with nobody else involved.
--
-- The PIN is the secret; the name and phone only say who is claiming to sign in.
--
-- Where the PIN is verified: NOT here. Hashing and comparison live in the
-- member-phone-login Edge Function, which holds the service-role key. Two
-- reasons. First, a PIN has at most 10^6 possibilities, so no hash cost saves it
-- from an offline guess — the only control that matters is a server-side attempt
-- limit, which needs a trusted caller. Second, doing it in Postgres would mean a
-- SECURITY DEFINER function reachable from PostgREST that takes a PIN and
-- answers yes or no, which is the oracle this is trying not to build.
--
-- Nothing in this file is readable or writable by `authenticated`. Both tables
-- are RLS-enabled with no policies at all, so only the service role reaches
-- them. That is intentional and is asserted in 15_phone_pin_login.test.sql.
--
-- Requires 001 (profiles), 007 (audit_log). Independent of 041 (the overseer):
-- nothing here touches required_approvals() or is_superadmin.

-- --------------------------------------------------------------------------
-- 1. Phone normalisation
--
-- Admins type a phone number three different ways for the same handset:
-- +255712345678, 255712345678 and 0712345678. `profiles.phone_number` is UNIQUE
-- (001), which blocks an exact repeat but not those three, so without a
-- canonical form two profiles could hold the same real number and the login
-- lookup would match both.
--
-- Canonical form is the 9-digit Tanzanian subscriber number (7xxxxxxxx /
-- 6xxxxxxxx). IMMUTABLE so it can carry a unique index.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION normalize_phone_tz(p_phone text)
RETURNS text AS $$
DECLARE
  v_digits text;
BEGIN
  IF p_phone IS NULL THEN RETURN NULL; END IF;

  v_digits := regexp_replace(p_phone, '\D', '', 'g');
  IF v_digits = '' THEN RETURN NULL; END IF;

  -- Strip the country code or the trunk prefix, whichever this form used.
  IF length(v_digits) = 12 AND left(v_digits, 3) = '255' THEN
    v_digits := right(v_digits, 9);
  ELSIF length(v_digits) = 10 AND left(v_digits, 1) = '0' THEN
    v_digits := right(v_digits, 9);
  END IF;

  -- Anything that is not a 9-digit subscriber number by now is not a number we
  -- can canonicalise. Return it as digits rather than NULL: a foreign or
  -- malformed number must still compare equal to itself, or two members holding
  -- the same unparseable string would both look like "no phone" and the
  -- uniqueness guard below would not see the collision.
  RETURN v_digits;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- First name, lowercased, for the confirmation check at login. Never a selector
-- on its own — two members may share a first name; the phone is the key.
CREATE OR REPLACE FUNCTION member_first_name(p_full_name text)
RETURNS text AS $$
  SELECT lower(split_part(btrim(coalesce(p_full_name, '')), ' ', 1));
$$ LANGUAGE sql IMMUTABLE;

-- --------------------------------------------------------------------------
-- 2. Refuse to proceed if live data already holds a collision
--
-- The unique index below would fail on its own, but with "could not create
-- unique index" and a row count — not with the two numbers an admin has to go
-- and fix. Failing here, by hand, in the SQL editor where someone is looking,
-- is the same posture 039 takes for a drain that cannot run.
-- --------------------------------------------------------------------------

DO $$
DECLARE
  v_dupes text;
BEGIN
  SELECT string_agg(detail, E'\n  ') INTO v_dupes
  FROM (
    SELECT normalize_phone_tz(phone_number) || ' ← ' ||
           string_agg(full_name || ' (' || phone_number || ')', ', ' ORDER BY full_name)
             AS detail
    FROM profiles
    WHERE phone_number IS NOT NULL
    GROUP BY normalize_phone_tz(phone_number)
    HAVING count(*) > 1
  ) d;

  IF v_dupes IS NOT NULL THEN
    RAISE EXCEPTION E'Two or more profiles share a phone number once normalised:\n  %\n\nPhone number is half of the new login credential, so it has to identify exactly one member. Correct these in the admin member list, then re-run this migration.', v_dupes;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS profiles_normalized_phone_key
  ON profiles (normalize_phone_tz(phone_number))
  WHERE phone_number IS NOT NULL;

-- --------------------------------------------------------------------------
-- 3. member_pins — one PIN per member, hashed
--
-- `must_change` is true for a PIN an admin set (a handover code, spoken aloud)
-- and false once the member has chosen their own. It is the same distinction the
-- temp password carried, kept because it is the only thing that separates "a PIN
-- the member knows" from "a PIN the admin also knows".
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS member_pins (
  member_id   uuid PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  pin_hash    text        NOT NULL,
  must_change boolean     NOT NULL DEFAULT true,
  set_at      timestamptz NOT NULL DEFAULT now(),
  set_by      uuid        REFERENCES profiles(id),  -- NULL when the member set it
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- RLS on, no policies: service role only. A member's PIN hash is not something
-- the member's own session needs to read, and `authenticated` reaching this
-- table at all would hand every member the group's password file.
ALTER TABLE member_pins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON member_pins FROM anon, authenticated;

-- --------------------------------------------------------------------------
-- 4. phone_login_attempts — the attempt limit
--
-- Keyed on the normalised phone the caller TYPED, not on a member id, so a
-- number that matches no member is throttled exactly like one that does. That
-- is what stops the endpoint answering "is this number in the group?" — without
-- it, five wrong guesses against a real member get a lockout message and five
-- against a stranger get a generic one, and the difference is the answer.
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS phone_login_attempts (
  phone_key       text PRIMARY KEY,
  attempts        int         NOT NULL DEFAULT 0,
  first_attempt_at timestamptz NOT NULL DEFAULT now(),
  last_attempt_at timestamptz NOT NULL DEFAULT now(),
  locked_until    timestamptz
);

ALTER TABLE phone_login_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON phone_login_attempts FROM anon, authenticated;

-- --------------------------------------------------------------------------
-- 5. own_pin_status() — what the app may ask about its own session
--
-- The app needs exactly two facts to decide whether to show the "choose your
-- PIN" screen: does this member have a PIN, and was it set by an admin. Scoped
-- to auth.uid(), so it cannot be asked about anyone else.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION own_pin_status()
RETURNS TABLE (has_pin boolean, must_change boolean) AS $$
  SELECT
    p.member_id IS NOT NULL,
    coalesce(p.must_change, false)
  FROM (SELECT auth.uid() AS uid) me
  LEFT JOIN member_pins p ON p.member_id = me.uid;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION own_pin_status() FROM public, anon;
GRANT EXECUTE ON FUNCTION own_pin_status() TO authenticated;

-- --------------------------------------------------------------------------
-- 6. member_pin_overview() — admin view of who can actually sign in
--
-- Returns whether a PIN exists and whether the member is currently locked out.
-- Never the hash. An admin handing out logins needs to see who has not set one
-- yet; that is the whole purpose.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION member_pin_overview()
RETURNS TABLE (
  member_id    uuid,
  full_name    text,
  has_pin      boolean,
  must_change  boolean,
  set_at       timestamptz,
  locked_until timestamptz
) AS $$
  SELECT
    pr.id,
    pr.full_name,
    mp.member_id IS NOT NULL,
    coalesce(mp.must_change, false),
    mp.set_at,
    la.locked_until
  FROM profiles pr
  LEFT JOIN member_pins mp ON mp.member_id = pr.id
  LEFT JOIN phone_login_attempts la
         ON la.phone_key = normalize_phone_tz(pr.phone_number)
        AND la.locked_until > now()
  WHERE pr.is_active
    AND is_admin()
  ORDER BY pr.full_name;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION member_pin_overview() FROM public, anon;
GRANT EXECUTE ON FUNCTION member_pin_overview() TO authenticated;

-- --------------------------------------------------------------------------
-- 7. What these tables are, for whoever opens them next
--
-- No audit trigger here: the two events worth recording are a member choosing
-- their own PIN and an admin issuing one, and both are already written to
-- audit_log as `set_own_pin` and `admin_reset_pin` by the member-pin-auth Edge
-- Function, which is the only thing that can write these tables at all. A
-- trigger would either duplicate those rows or record the service role as the
-- actor, which is the one fact the log does not need.
-- --------------------------------------------------------------------------

COMMENT ON TABLE member_pins IS
  'Hashed member login PINs. Service role only — verified in the member-pin-auth Edge Function, never in SQL.';
COMMENT ON TABLE phone_login_attempts IS
  'Per-phone attempt limiter for PIN login. Keyed on the typed number so unknown numbers throttle identically to known ones.';

-- --------------------------------------------------------------------------
-- 8. Service-role surface for the Edge Functions
--
-- Three functions the member-phone-login function calls, and nothing else can.
-- They are SECURITY DEFINER but every grant to public/anon/authenticated is
-- revoked, so they are unreachable from PostgREST with an anon or member JWT.
-- The grant to service_role is guarded: the SQL test harness is a plain Postgres
-- where that role does not exist (bootstrap.sql creates only authenticated and
-- anon), and an unguarded GRANT would abort the migration and take CI with it.
--
-- Keeping the phone lookup in SQL rather than re-deriving it in TypeScript is
-- deliberate: normalize_phone_tz is the one definition of what counts as the
-- same number, and it is the same definition the unique index enforces. A second
-- copy in Deno would be free to drift from the index that guarantees the lookup
-- returns one row.
-- --------------------------------------------------------------------------

-- Everything member-phone-login needs to decide a login, in one round trip.
-- Returns no row when the number matches nobody, which the caller must treat
-- identically to a wrong name or a wrong PIN.
CREATE OR REPLACE FUNCTION lookup_phone_login(p_phone text)
RETURNS TABLE (
  member_id   uuid,
  email       text,
  first_name  text,
  is_active   boolean,
  pin_hash    text,
  must_change boolean
) AS $$
  SELECT
    pr.id,
    u.email::text,
    member_first_name(pr.full_name),
    pr.is_active,
    mp.pin_hash,
    coalesce(mp.must_change, false)
  FROM profiles pr
  JOIN auth.users u ON u.id = pr.id
  LEFT JOIN member_pins mp ON mp.member_id = pr.id
  WHERE pr.phone_number IS NOT NULL
    AND normalize_phone_tz(pr.phone_number) = normalize_phone_tz(p_phone);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;

-- Take one attempt against this number. Returns the lock expiry if the number is
-- already locked out (caller must refuse without looking at the PIN), else NULL.
--
-- The counter is keyed on the TYPED number and resets after a quiet window, so a
-- member who fumbles a digit one month does not carry that toward a lock the
-- next. Attempts are counted before verification, never after, so a caller that
-- crashes mid-verify still spends the attempt.
CREATE OR REPLACE FUNCTION begin_login_attempt(
  p_phone_key     text,
  p_max_attempts  int DEFAULT 5,
  p_lock_minutes  int DEFAULT 15,
  p_window_minutes int DEFAULT 30
)
RETURNS timestamptz AS $$
DECLARE
  v_row phone_login_attempts;
BEGIN
  SELECT * INTO v_row FROM phone_login_attempts
   WHERE phone_key = p_phone_key FOR UPDATE;

  IF v_row.phone_key IS NOT NULL AND v_row.locked_until > now() THEN
    RETURN v_row.locked_until;
  END IF;

  -- Locked but expired, or quiet for longer than the window: start fresh.
  IF v_row.phone_key IS NULL
     OR v_row.locked_until IS NOT NULL
     OR v_row.first_attempt_at < now() - make_interval(mins => p_window_minutes) THEN
    INSERT INTO phone_login_attempts (phone_key, attempts, first_attempt_at, last_attempt_at, locked_until)
    VALUES (p_phone_key, 1, now(), now(), NULL)
    ON CONFLICT (phone_key) DO UPDATE
      SET attempts = 1, first_attempt_at = now(), last_attempt_at = now(), locked_until = NULL;
    RETURN NULL;
  END IF;

  -- `>` and not `>=`: the attempt being counted here is one the caller is about to
  -- make, so locking at `= p_max_attempts` would refuse the fifth try and allow only
  -- four. Attempts 1..p_max_attempts are verified; the one after that is refused.
  UPDATE phone_login_attempts
     SET attempts = attempts + 1,
         last_attempt_at = now(),
         locked_until = CASE WHEN attempts + 1 > p_max_attempts
                             THEN now() + make_interval(mins => p_lock_minutes)
                             ELSE NULL END
   WHERE phone_key = p_phone_key
   RETURNING locked_until INTO v_row.locked_until;

  RETURN v_row.locked_until;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- A correct PIN clears the count. Called only after verification succeeds.
CREATE OR REPLACE FUNCTION clear_login_attempts(p_phone_key text)
RETURNS void AS $$
  DELETE FROM phone_login_attempts WHERE phone_key = p_phone_key;
$$ LANGUAGE sql SECURITY DEFINER SET search_path = public;

-- REVOKE from anon and authenticated BY NAME, not just from public.
--
-- `REVOKE ... FROM public` alone is not enough and the first run of
-- 15_phone_pin_login.test.sql proved it: Supabase ships
-- `ALTER DEFAULT PRIVILEGES ... GRANT ALL ON FUNCTIONS TO postgres, anon,
-- authenticated, service_role`, so these roles receive an EXPLICIT grant the
-- moment the function is created. Revoking the implicit PUBLIC grant leaves that
-- explicit one standing, and lookup_phone_login stayed callable with a member's
-- JWT — a phone-number-to-member directory for anyone signed in.
REVOKE ALL ON FUNCTION lookup_phone_login(text) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION begin_login_attempt(text, int, int, int) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION clear_login_attempts(text) FROM public, anon, authenticated;

DO $$
BEGIN
  -- Present on Supabase, absent in the test harness.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION lookup_phone_login(text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION begin_login_attempt(text, int, int, int) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION clear_login_attempts(text) TO service_role';
  END IF;
END $$;

-- --------------------------------------------------------------------------
-- 9. update_own_phone() — say what went wrong in words
--
-- A member changing their own phone number is now changing half of their login
-- credential, and the unique index added above can refuse the write. 006's
-- version was a bare UPDATE, so a collision would surface in the Profile screen
-- as `duplicate key value violates unique constraint
-- "profiles_normalized_phone_key"` — which names an index the member has no way
-- to act on, and tells them nothing about what to do.
--
-- Same function, same permissions, with the two failures a member can actually
-- cause turned into sentences. Replaces the definition in 006.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION update_own_phone(p_phone text)
RETURNS void AS $$
DECLARE
  v_phone text := NULLIF(btrim(p_phone), '');
BEGIN
  -- Clearing the number is allowed, but it costs the member their PIN login, so
  -- it should not be something they do by accident with an empty field.
  IF v_phone IS NULL THEN
    RAISE EXCEPTION 'Enter a phone number — it is how you sign in.';
  END IF;

  UPDATE profiles
     SET phone_number = v_phone
   WHERE id = auth.uid();

EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Another member is already registered with that phone number. Check the digits, or ask your admin.';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION update_own_phone(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION update_own_phone(text) TO authenticated;

-- A number that is already taken, reported before anything is written. Used by
-- admin-create-member so adding a member with a duplicate number fails with a
-- sentence instead of "Database error creating new user" from the signup trigger.
CREATE OR REPLACE FUNCTION phone_number_taken(p_phone text, p_except uuid DEFAULT NULL)
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
     WHERE phone_number IS NOT NULL
       AND normalize_phone_tz(phone_number) = normalize_phone_tz(p_phone)
       AND (p_except IS NULL OR id <> p_except)
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION phone_number_taken(text, uuid) FROM public, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION phone_number_taken(text, uuid) TO service_role';
  END IF;
END $$;
