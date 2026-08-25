-- fixtures.sql — impersonation and fixture builders for the SQL tests.
--
-- Applied AFTER the migrations by scripts/test-db.mjs, so it can see every table
-- and function the migrations created. Lives in a `tests` schema and is never part
-- of a production database.
--
-- Two jobs:
--   1. Replicate the table grants Supabase applies to `authenticated` by default.
--      The migrations rely on those existing and only add the view/function grants
--      on top, so without this every test would fail on permissions rather than on
--      the logic it is actually checking.
--   2. Give the tests a way to BE a particular member, since all 33 RPCs gate on
--      auth.uid() / is_admin().

CREATE SCHEMA IF NOT EXISTS tests;

-- The `authenticated` grants on the public schema have MOVED to bootstrap.sql, as
-- ALTER DEFAULT PRIVILEGES. They cannot live here: this file is applied after the
-- migrations, so a blanket GRANT re-granted whatever a migration had revoked, and
-- no privilege lockdown could be tested (034 revokes EXECUTE on the execute_*
-- family and UPDATE on profiles). Default privileges grant at CREATE time instead,
-- which is what Supabase actually does. See bootstrap.sql.

-- ---------------------------------------------------------------------------
-- Impersonation
-- ---------------------------------------------------------------------------

-- Become `p_id` for the rest of the transaction. SET LOCAL so a ROLLBACK between
-- test files cannot leak identity into the next one.
--
-- Setting the ROLE matters as much as the claim: the owning superuser bypasses RLS
-- entirely, so a test that only set the claim would silently prove nothing about
-- the policies. SECURITY DEFINER functions still run as their owner, exactly as in
-- production.
CREATE OR REPLACE FUNCTION tests.as_user(p_id uuid)
RETURNS void AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', p_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
END;
$$ LANGUAGE plpgsql;

-- Drop back to the owning role (needed before creating more fixtures).
CREATE OR REPLACE FUNCTION tests.as_owner()
RETURNS void AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claim.role', '', true);
  EXECUTE 'RESET ROLE';
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- Fixture builders
--
-- All SECURITY DEFINER: a test is often mid-impersonation when it needs to set up
-- the next scenario, and RLS would then refuse (an admin cannot INSERT a
-- submission on a member's behalf — correctly). Fixtures are scaffolding, not the
-- thing under test, so they run as the owner and bypass RLS. Anything that IS
-- under test is called directly by the test, never through a helper.
-- ---------------------------------------------------------------------------

-- Inserting into auth.users fires handle_new_user(), which creates the profile —
-- the same path a real signup takes, so the trigger is exercised too.
CREATE OR REPLACE FUNCTION tests.make_member(p_name text, p_admin boolean DEFAULT false)
RETURNS uuid AS $$
DECLARE
  v_id uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, email, raw_user_meta_data)
  VALUES (
    v_id,
    lower(replace(p_name, ' ', '.')) || '@test.local',
    jsonb_build_object('full_name', p_name)
  );

  UPDATE profiles
     SET role = CASE WHEN p_admin THEN 'admin' ELSE 'member' END,
         is_active = true,
         full_name = p_name
   WHERE id = v_id;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, tests;

CREATE OR REPLACE FUNCTION tests.make_admin(p_name text)
RETURNS uuid AS $$
  SELECT tests.make_member(p_name, true);
$$ LANGUAGE sql SECURITY DEFINER SET search_path = public, auth, tests;

-- An approved savings deposit of `p_amount`, dated `p_at`. Bypasses the approval
-- RPC on purpose: most tests need capital to already exist and are not testing the
-- deposit path itself. `reviewed_at` is what v_member_capital_events reads, so the
-- date has to be settable for the time-weighting tests.
CREATE OR REPLACE FUNCTION tests.give_savings(
  p_member uuid, p_amount numeric, p_at timestamptz DEFAULT now()
)
RETURNS uuid AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO payment_submissions
    (member_id, submission_type, amount_claimed, proof_url, status, submitted_at, reviewed_at)
  VALUES (p_member, 'savings_deposit', p_amount, 'test://proof', 'approved', p_at, p_at)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, tests;

-- A pending fee for a given period, so the allocation tests have something to pay.
CREATE OR REPLACE FUNCTION tests.give_fee(
  p_member uuid, p_period date, p_amount numeric DEFAULT NULL
)
RETURNS uuid AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO monthly_fees (member_id, period, amount, status)
  VALUES (p_member, p_period, COALESCE(p_amount, setting('monthly_fee_amount')), 'pending')
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, tests;

-- A member-submitted payment awaiting review.
CREATE OR REPLACE FUNCTION tests.submit_payment(
  p_member uuid, p_type text, p_related uuid, p_amount numeric
)
RETURNS uuid AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO payment_submissions
    (member_id, submission_type, related_id, amount_claimed, proof_url, status)
  VALUES (p_member, p_type, p_related, p_amount, 'test://proof', 'pending')
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, tests;

-- ---------------------------------------------------------------------------
-- Assertions
-- ---------------------------------------------------------------------------

-- Money comparison with an explicit message. Numeric equality is exact here by
-- design: every figure in this system is whole shillings, so a mismatch of one is
-- a real defect, not a rounding artefact.
CREATE OR REPLACE FUNCTION tests.eq(p_actual numeric, p_expected numeric, p_what text)
RETURNS void AS $$
BEGIN
  IF p_actual IS DISTINCT FROM p_expected THEN
    RAISE EXCEPTION '% — expected %, got %', p_what, p_expected, p_actual;
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION tests.eq(p_actual text, p_expected text, p_what text)
RETURNS void AS $$
BEGIN
  IF p_actual IS DISTINCT FROM p_expected THEN
    RAISE EXCEPTION '% — expected %, got %', p_what, p_expected, p_actual;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Asserts that `p_sql` raises. Used for every guard: an approval that should be
-- refused, a withdrawal over the collateral cap, an over-payment.
CREATE OR REPLACE FUNCTION tests.raises(p_sql text, p_what text)
RETURNS void AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    RETURN;  -- raised as required
  END;
  RAISE EXCEPTION '% — expected an error, but the statement succeeded', p_what;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION tests.pool()
RETURNS numeric AS $$
  SELECT pool_balance_tzs FROM v_group_pool;
$$ LANGUAGE sql;

-- Assets must equal claims (migration 027). Called after every money movement in
-- 03_pool.test.sql: a money path that one side of the identity does not know about
-- is exactly the class of bug the reconciliation view exists to surface.
CREATE OR REPLACE FUNCTION tests.assert_balanced(p_after text)
RETURNS void AS $$
DECLARE
  v record;
BEGIN
  SELECT * INTO v FROM v_pool_reconciliation;
  IF NOT v.balanced THEN
    RAISE EXCEPTION
      'books do not balance after %: assets % (pool % + out %) vs claims % (capital % + earnings % + adj %), off by %',
      p_after, v.total_assets_tzs, v.pool_tzs, v.outstanding_tzs, v.total_claims_tzs,
      v.member_capital_tzs, v.retained_earnings_tzs, v.pool_adjustments_tzs, v.difference_tzs;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, tests;

GRANT USAGE ON SCHEMA tests TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA tests TO authenticated;
