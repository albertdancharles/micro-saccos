-- bootstrap.sql — the minimum Supabase surface the migrations need, so the REAL,
-- UNMODIFIED migrations can be applied to any plain Postgres 15+.
--
-- Why this exists: the money logic lives in plpgsql, and until now nothing tested
-- it. Standing up a full Supabase stack to test it needs Docker, which this project
-- deliberately does without (see supabase/README.md). But a grep across all
-- migrations finds only four things outside `public`:
--
--     auth.uid()      197 uses
--     auth.users        7 foreign-key / delete references
--     storage.*         only in 004
--     cron.*            only in 017 and 026
--
-- All of it fits in this file. The point is that the migrations are applied here
-- byte-for-byte identically to production — there is no forked test schema that can
-- drift away from what actually ships.
--
-- Applied BEFORE the migrations by scripts/test-db.mjs.

-- ---------------------------------------------------------------------------
-- Roles. Supabase provisions these; plain Postgres does not, and 36 GRANT
-- statements across the migrations target `authenticated`.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
END;
$$;

GRANT USAGE ON SCHEMA public TO authenticated, anon;

-- ---------------------------------------------------------------------------
-- auth. Only the columns the migrations actually read: `id` (FK target),
-- `email` (018's signup trigger, 010's deletion audit) and `raw_user_meta_data`
-- (001/018 read the signup payload out of it).
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email              text,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT now()
);

-- Supabase derives auth.uid() from the request JWT. Here it comes from a GUC that
-- tests/fixtures.sql's as_user() sets, which keeps the impersonation mechanism in
-- one place. current_setting(..., true) returns NULL when unset rather than
-- raising, so an unauthenticated query behaves like a signed-out request.
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(NULLIF(current_setting('request.jwt.claim.role', true), ''), 'anon');
$$;

GRANT USAGE ON SCHEMA auth TO authenticated, anon;
GRANT EXECUTE ON FUNCTION auth.uid(), auth.role() TO authenticated, anon;

-- ---------------------------------------------------------------------------
-- storage. Migration 004 is SKIPPED by the runner (it is bucket configuration and
-- object policies — no business logic to test), but the schema is created anyway
-- so that skipping it is a runner decision rather than a hard dependency.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS storage;

CREATE TABLE IF NOT EXISTS storage.buckets (
  id                 text PRIMARY KEY,
  name               text NOT NULL,
  public             boolean NOT NULL DEFAULT false,
  file_size_limit    bigint,
  allowed_mime_types text[]
);

CREATE TABLE IF NOT EXISTS storage.objects (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id  text REFERENCES storage.buckets(id),
  name       text NOT NULL,
  owner      uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- Supabase's helper: splits an object path into its folder segments.
CREATE OR REPLACE FUNCTION storage.foldername(name text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT string_to_array(name, '/');
$$;

GRANT USAGE ON SCHEMA storage TO authenticated;

-- ---------------------------------------------------------------------------
-- cron. Migration 017 is SKIPPED by the runner because it opens with
-- `create extension if not exists pg_cron`, which cannot succeed where the
-- extension binary is absent. 026 guards its own cron block on pg_extension, so it
-- applies cleanly and simply takes the RAISE NOTICE branch. These no-op stand-ins
-- exist so that a future migration calling cron.schedule() outside a guard fails
-- loudly in review rather than silently at deploy time.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS cron;

CREATE TABLE IF NOT EXISTS cron.job (
  jobid    bigserial PRIMARY KEY,
  jobname  text UNIQUE,
  schedule text,
  command  text,
  active   boolean NOT NULL DEFAULT true
);

CREATE OR REPLACE FUNCTION cron.schedule(p_name text, p_schedule text, p_command text)
RETURNS bigint AS $$
  INSERT INTO cron.job (jobname, schedule, command)
  VALUES (p_name, p_schedule, p_command)
  ON CONFLICT (jobname) DO UPDATE
    SET schedule = EXCLUDED.schedule, command = EXCLUDED.command
  RETURNING jobid;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION cron.unschedule(p_name text)
RETURNS boolean AS $$
  DELETE FROM cron.job WHERE jobname = p_name RETURNING true;
$$ LANGUAGE sql;
