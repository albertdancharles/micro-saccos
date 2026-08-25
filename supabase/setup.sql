-- ===========================================================================
-- setup.sql — GENERATED FILE. DO NOT EDIT BY HAND.
--
-- Every migration in supabase/migrations, concatenated in order, for the hosted
-- one-shot paste: Supabase Dashboard -> SQL Editor -> New query -> Run.
--
-- Regenerate with:  npm run build:setup
-- CI fails if this file does not match the migrations it is built from.
--
-- Two migrations need a note when running this on a fresh project:
--   * 004 requires the storage schema (present on every Supabase project)
--   * 017 enables pg_cron. If the extension is not available the statement RAISES
--     and the SQL editor aborts the batch there, so everything after 017 is
--     missing too — enable pg_cron and paste from 017 on. Do not just skip it:
--     since the admin mandate, ensure_current_fees() runs only when an ADMIN
--     opens the dashboard (a member opening theirs used to trigger it, which was
--     a member-initiated write), so without the cron job fee generation waits on
--     an admin logging in.
--
-- 37 migrations: 001_create_tables.sql .. 037_payment_void.sql
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 001_create_tables.sql
-- ---------------------------------------------------------------------------

-- 001_create_tables.sql — Micro-SACCOS schema (build plan §4).
-- Apply order: 001 tables → 002 views → 003 RLS → 004 storage → 005 RPCs.

-- Timezone helper: "today" in East Africa Time (UTC+3, Africa/Dar_es_Salaam).
-- Defined here so the views (002) and RPCs (005) can both use it. Never use raw
-- CURRENT_DATE — it is UTC and drifts month boundaries by a day.
CREATE OR REPLACE FUNCTION today_eat()
RETURNS date AS $$
  SELECT (now() AT TIME ZONE 'Africa/Dar_es_Salaam')::date;
$$ LANGUAGE sql STABLE;

-- profiles: extends auth.users. All 15 are contributing members; `role` only
-- gates permissions (Decision #1). Created automatically on signup by a trigger.
CREATE TABLE profiles (
  id            uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name     text NOT NULL,
  phone_number  text UNIQUE,
  role          text NOT NULL DEFAULT 'member' CHECK (role IN ('admin', 'member')),
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- SECURITY DEFINER + pinned search_path: this trigger fires under the
-- supabase_auth_admin role (GoTrue), whose search_path excludes `public`, so the
-- table must be schema-qualified and search_path pinned or every signup fails with
-- "Database error creating new user".
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, phone_number)
  VALUES (NEW.id,
          NEW.raw_user_meta_data->>'full_name',
          NEW.raw_user_meta_data->>'phone_number');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE handle_new_user();

-- monthly_fees: one per active profile per month (admin included). Auto-generated
-- on the 1st; `status` is pending/paid only (overdue is computed in the views).
CREATE TABLE monthly_fees (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id         uuid NOT NULL REFERENCES profiles(id),
  period            date NOT NULL,                    -- always the 1st of the month
  amount            numeric(12,2) NOT NULL DEFAULT 10000,
  status            text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid')),
  penalty_collected numeric(12,2) NOT NULL DEFAULT 0, -- accrued penalty banked at payment
  paid_at           timestamptz,
  reviewed_by       uuid REFERENCES profiles(id),
  UNIQUE (member_id, period)
);

-- loans: a member may hold only one non-terminal loan at a time (Decision #4,
-- enforced in submitLoanRequest). Disbursement proof is captured at approval.
CREATE TABLE loans (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id              uuid NOT NULL REFERENCES profiles(id),
  principal              numeric(12,2) NOT NULL CHECK (principal > 0),
  status                 text NOT NULL DEFAULT 'pending'
                           CHECK (status IN ('pending', 'active', 'closed', 'rejected')),
  requested_at           timestamptz NOT NULL DEFAULT now(),
  approved_at            timestamptz,
  approved_by            uuid REFERENCES profiles(id),
  disbursed_at           timestamptz,
  disbursement_proof_url text,
  rejection_reason       text
);

-- loan_installments: exactly 3 per approved loan, interest only (no fee, Decision #2).
-- Bullet schedule: M1/M2 interest, M3 principal + interest.
CREATE TABLE loan_installments (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_id             uuid NOT NULL REFERENCES loans(id) ON DELETE CASCADE,
  installment_number  int NOT NULL CHECK (installment_number IN (1, 2, 3)),
  due_date            date NOT NULL,
  principal_due       numeric(12,2) NOT NULL DEFAULT 0,   -- 0 for M1/M2, full principal M3
  interest_due        numeric(12,2) NOT NULL,             -- principal × 0.05, whole TZS
  total_due           numeric(12,2) GENERATED ALWAYS AS (principal_due + interest_due) STORED,
  status              text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid')),
  penalty_collected   numeric(12,2) NOT NULL DEFAULT 0,
  proof_url           text,
  paid_at             timestamptz,
  reviewed_by         uuid REFERENCES profiles(id),
  UNIQUE (loan_id, installment_number)
);

-- payment_submissions: single intake for ALL proofs (Decision #3). related_id is
-- NULL for savings deposits; for monthly_fee / loan_installment it points at the
-- row whose status flips to paid on approval.
CREATE TABLE payment_submissions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id        uuid NOT NULL REFERENCES profiles(id),
  submission_type  text NOT NULL
                     CHECK (submission_type IN ('savings_deposit', 'monthly_fee', 'loan_installment')),
  related_id       uuid,
  amount_claimed   numeric(12,2) NOT NULL CHECK (amount_claimed > 0),
  proof_url        text NOT NULL,
  status           text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  submitted_at     timestamptz NOT NULL DEFAULT now(),
  reviewed_at      timestamptz,
  reviewed_by      uuid REFERENCES profiles(id),
  rejection_reason text
);

-- ---------------------------------------------------------------------------
-- 002_create_views.sql
-- ---------------------------------------------------------------------------

-- 002_create_views.sql — overdue + penalty computed at query time (build plan §5).
-- Penalty rule (Decision #6): once past due, 5% × base applies and again each
-- completed month thereafter (simple, non-compounding). penalty_months is the
-- multiplier. All "today" comparisons use today_eat(); penalties round to whole TZS.

-- Monthly fees: due by the end of the period's month (period + 1 month).
CREATE OR REPLACE VIEW v_fee_status AS
WITH b AS (
  SELECT mf.*, (mf.period + INTERVAL '1 month')::date AS due_date
  FROM monthly_fees mf
)
SELECT
  b.*,
  CASE
    WHEN b.status = 'paid' OR today_eat() <= b.due_date THEN 0
    ELSE (date_part('year',  age(today_eat(), b.due_date)) * 12
        + date_part('month', age(today_eat(), b.due_date)))::int + 1
  END AS penalty_months,
  CASE
    WHEN b.status = 'paid'        THEN 'paid'
    WHEN today_eat() > b.due_date THEN 'overdue'
    ELSE 'pending'
  END AS computed_status
FROM b;

CREATE OR REPLACE VIEW v_fee_status_money AS
SELECT
  f.*,
  round(0.05 * f.amount * f.penalty_months)            AS penalty_due,
  f.amount + round(0.05 * f.amount * f.penalty_months) AS total_with_penalty
FROM v_fee_status f;

-- Loan installments: overdue if past due_date and not paid. Penalty base = total_due.
CREATE OR REPLACE VIEW v_installment_status AS
SELECT
  li.*,
  CASE
    WHEN li.status = 'paid' OR today_eat() <= li.due_date THEN 0
    ELSE (date_part('year',  age(today_eat(), li.due_date)) * 12
        + date_part('month', age(today_eat(), li.due_date)))::int + 1
  END AS penalty_months,
  CASE
    WHEN li.status = 'paid'        THEN 'paid'
    WHEN today_eat() > li.due_date THEN 'overdue'
    ELSE 'pending'
  END AS computed_status
FROM loan_installments li;

CREATE OR REPLACE VIEW v_installment_status_money AS
SELECT
  i.*,
  round(0.05 * i.total_due * i.penalty_months)               AS penalty_due,
  i.total_due + round(0.05 * i.total_due * i.penalty_months) AS total_with_penalty
FROM v_installment_status i;

-- Group pool balance (single aggregate; no member breakdown).
-- Cash in:  approved savings + paid fees (+ collected penalty) + paid installments (+ collected penalty)
-- Cash out: principal disbursed for active & closed loans
CREATE OR REPLACE VIEW v_group_pool AS
SELECT
    (SELECT COALESCE(SUM(amount_claimed), 0)
       FROM payment_submissions
       WHERE submission_type = 'savings_deposit' AND status = 'approved')
  + (SELECT COALESCE(SUM(amount), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM monthly_fees      WHERE status = 'paid')
  + (SELECT COALESCE(SUM(total_due), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM loan_installments WHERE status = 'paid')
  - (SELECT COALESCE(SUM(principal), 0)
       FROM loans             WHERE status IN ('active', 'closed'))
  AS pool_balance_tzs;

-- ---------------------------------------------------------------------------
-- 003_rls_policies.sql
-- ---------------------------------------------------------------------------

-- 003_rls_policies.sql — Row-Level Security (build plan §6).
-- Privileged writes (fee generation, loan/payment approval) go through the service
-- role (Edge Function) or SECURITY DEFINER RPCs, so base tables need no write policy
-- for those paths.

-- Helper: is the current user an admin? SECURITY DEFINER bypasses RLS → no recursion.
CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  );
$$ LANGUAGE sql SECURITY DEFINER;

-- profiles
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Members see own profile, admin sees all"
  ON profiles FOR SELECT USING (id = auth.uid() OR is_admin());
CREATE POLICY "Admin can update any profile"
  ON profiles FOR UPDATE USING (is_admin());

-- monthly_fees (rows created by Edge Function via service role; status flipped by RPC)
ALTER TABLE monthly_fees ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Member sees own fees"
  ON monthly_fees FOR SELECT USING (member_id = auth.uid() OR is_admin());

-- loans
ALTER TABLE loans ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Member sees own loans"
  ON loans FOR SELECT USING (member_id = auth.uid() OR is_admin());
CREATE POLICY "Member inserts loan request"
  ON loans FOR INSERT WITH CHECK (member_id = auth.uid() AND status = 'pending');
-- approval/rejection happen via approve_loan / reject_loan RPCs

-- loan_installments (created + flipped by RPC only)
ALTER TABLE loan_installments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Member sees own installments via loan"
  ON loan_installments FOR SELECT USING (
    loan_id IN (SELECT id FROM loans WHERE member_id = auth.uid()) OR is_admin()
  );

-- payment_submissions
ALTER TABLE payment_submissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Member sees own submissions"
  ON payment_submissions FOR SELECT USING (member_id = auth.uid() OR is_admin());
CREATE POLICY "Member inserts own submission"
  ON payment_submissions FOR INSERT WITH CHECK (member_id = auth.uid() AND status = 'pending');
-- approval/rejection happen via approve_submission / reject_submission RPCs

-- Views: aggregate pool is safe for all authenticated users; status/money views rely
-- on the underlying table RLS (security_invoker default) so members see only their rows.
GRANT SELECT ON v_group_pool TO authenticated;
GRANT SELECT ON v_fee_status, v_fee_status_money,
                v_installment_status, v_installment_status_money TO authenticated;

-- ---------------------------------------------------------------------------
-- 004_storage_bucket.sql
-- ---------------------------------------------------------------------------

-- 004_storage_bucket.sql — private proof bucket + storage RLS (build plan §7).

-- Bucket: private, images only, ≤ 5 MB. Supabase enforces mime/size server-side.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('payment-proofs', 'payment-proofs', false, 5242880,
        ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE
  SET file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Path structure puts member_id as the 2nd segment for member uploads, e.g.
--   savings/{member_id}/{submission_id}.jpg
--   fees/{member_id}/{period}/{submission_id}.jpg
--   loan-repayments/{member_id}/{loan_id}/{installment_number}/{submission_id}.jpg
-- Admin disbursement proofs live under loan-disbursements/{loan_id}/...

-- Members upload only under their own id (2nd folder segment).
CREATE POLICY "member upload own proofs"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'payment-proofs'
              AND (storage.foldername(name))[2] = auth.uid()::text);

-- Members read their own files; admins read ALL files (so the admin client can mint
-- signed URLs directly — no service-role key in the browser).
CREATE POLICY "read own or admin"
  ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'payment-proofs'
         AND ((storage.foldername(name))[2] = auth.uid()::text OR is_admin()));

-- Admins upload disbursement proofs.
CREATE POLICY "admin upload disbursements"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'payment-proofs' AND is_admin());

-- ---------------------------------------------------------------------------
-- 005_rpc_functions.sql
-- ---------------------------------------------------------------------------

-- 005_rpc_functions.sql — SECURITY DEFINER RPCs (build plan §8b, §8c, §8c-bis).
-- These hold the atomic multi-write logic; never replicate it client-side.

-- Loan approval + schedule generation. Called as
-- supabase.rpc('approve_loan', { p_loan_id, p_proof_url }) after the admin uploads
-- the disbursement screenshot. Atomic: loan update + 3 installment inserts.
CREATE OR REPLACE FUNCTION approve_loan(p_loan_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_loan         loans%ROWTYPE;
  v_int          numeric(12,2);
  v_pool         numeric(14,2);
  v_contribution numeric(14,2);
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL          THEN RAISE EXCEPTION 'Loan not found';      END IF;
  IF v_loan.status <> 'pending' THEN RAISE EXCEPTION 'Loan is not pending'; END IF;

  -- Cap 1: a single loan may never exceed 25% of the current group pool, so one
  -- member can't drain it (whole TZS).
  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;
  IF v_loan.principal > floor(0.25 * COALESCE(v_pool, 0)) THEN
    RAISE EXCEPTION 'Loan exceeds 25%% of the group pool (max %).', floor(0.25 * COALESCE(v_pool, 0));
  END IF;

  -- Cap 2: a loan may never exceed 3x the member's contribution (approved savings
  -- + paid monthly fees). Penalties are excluded — they're fines, not contributions.
  SELECT
      COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                WHERE member_id = v_loan.member_id
                  AND submission_type = 'savings_deposit'
                  AND status = 'approved'), 0)
    + COALESCE((SELECT SUM(amount) FROM monthly_fees
                WHERE member_id = v_loan.member_id AND status = 'paid'), 0)
  INTO v_contribution;
  IF v_loan.principal > floor(3 * v_contribution) THEN
    RAISE EXCEPTION 'Loan exceeds 3x member contribution (max %).', floor(3 * v_contribution);
  END IF;

  v_int := round(v_loan.principal * 0.05);   -- 5% flat monthly interest, whole TZS

  UPDATE loans
    SET status = 'active', approved_at = now(), approved_by = auth.uid(),
        disbursed_at = now(), disbursement_proof_url = p_proof_url
    WHERE id = p_loan_id;

  -- Bullet schedule, due dates anchored to EAT "today".
  INSERT INTO loan_installments (loan_id, installment_number, due_date, principal_due, interest_due)
  VALUES
    (p_loan_id, 1, (today_eat() + INTERVAL '1 month')::date, 0,                v_int),
    (p_loan_id, 2, (today_eat() + INTERVAL '2 month')::date, 0,                v_int),
    (p_loan_id, 3, (today_eat() + INTERVAL '3 month')::date, v_loan.principal, v_int);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Payment approval. The admin passes the actual amount verified on the screenshot
-- (Decision #11); penalty banked = received − base (clamped ≥ 0). Auto-closes a loan
-- once all installments are paid. Called as
-- supabase.rpc('approve_submission', { p_submission_id, p_amount_received }).
CREATE OR REPLACE FUNCTION approve_submission(p_submission_id uuid, p_amount_received numeric)
RETURNS void AS $$
DECLARE
  s         payment_submissions%ROWTYPE;
  v_base    numeric(12,2);
  v_penalty numeric(12,2);
  v_loan_id uuid;
  v_open    int;
BEGIN
  IF NOT is_admin()              THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_amount_received IS NULL OR p_amount_received < 0
                                 THEN RAISE EXCEPTION 'Invalid amount received'; END IF;

  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id FOR UPDATE;
  IF s.id IS NULL          THEN RAISE EXCEPTION 'Submission not found'; END IF;
  IF s.status <> 'pending' THEN RAISE EXCEPTION 'Already reviewed';    END IF;

  UPDATE payment_submissions
    SET status = 'approved', reviewed_at = now(), reviewed_by = auth.uid()
    WHERE id = p_submission_id;

  IF s.submission_type = 'monthly_fee' THEN
    SELECT amount INTO v_base FROM monthly_fees WHERE id = s.related_id;
    v_penalty := greatest(0, p_amount_received - COALESCE(v_base, 0));
    UPDATE monthly_fees
      SET status = 'paid', paid_at = now(), reviewed_by = auth.uid(),
          penalty_collected = v_penalty
      WHERE id = s.related_id;

  ELSIF s.submission_type = 'loan_installment' THEN
    SELECT total_due INTO v_base FROM loan_installments WHERE id = s.related_id;
    v_penalty := greatest(0, p_amount_received - COALESCE(v_base, 0));
    UPDATE loan_installments
      SET status = 'paid', paid_at = now(), reviewed_by = auth.uid(),
          penalty_collected = v_penalty
      WHERE id = s.related_id
      RETURNING loan_id INTO v_loan_id;

    SELECT COUNT(*) INTO v_open
      FROM loan_installments WHERE loan_id = v_loan_id AND status <> 'paid';
    IF v_open = 0 THEN
      UPDATE loans SET status = 'closed' WHERE id = v_loan_id;
    END IF;

  ELSE  -- savings_deposit: confirmed amount becomes the source of truth
    UPDATE payment_submissions SET amount_claimed = p_amount_received
      WHERE id = p_submission_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Self-healing fee generation: idempotent, called on every dashboard load so the
-- current EAT month's fees always exist even if pg_cron was skipped while the free
-- project was paused (build plan §8c-bis, §13).
CREATE OR REPLACE FUNCTION ensure_current_fees()
RETURNS void AS $$
DECLARE
  v_period date := date_trunc('month', today_eat())::date;
BEGIN
  INSERT INTO monthly_fees (member_id, period, amount, status)
  SELECT p.id, v_period, 10000, 'pending'
  FROM profiles p
  WHERE p.is_active = true
  ON CONFLICT (member_id, period) DO NOTHING;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Rejections: set status only; the member resubmits. Rows are never hard-deleted.
CREATE OR REPLACE FUNCTION reject_submission(p_submission_id uuid, p_reason text)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE payment_submissions
    SET status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid(),
        rejection_reason = p_reason
    WHERE id = p_submission_id AND status = 'pending';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION reject_loan(p_loan_id uuid, p_reason text)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE loans
    SET status = 'rejected', rejection_reason = p_reason
    WHERE id = p_loan_id AND status = 'pending';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ---------------------------------------------------------------------------
-- 006_member_self_update.sql
-- ---------------------------------------------------------------------------

-- 006_member_self_update.sql — let members update their own phone number from the
-- Profile page without granting blanket UPDATE on profiles. SECURITY DEFINER scopes
-- the write to auth.uid()'s row only, so the policy surface stays minimal.

CREATE OR REPLACE FUNCTION update_own_phone(p_phone text)
RETURNS void AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  UPDATE public.profiles
     SET phone_number = NULLIF(trim(p_phone), '')
   WHERE id = auth.uid();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 007_audit_log.sql
-- ---------------------------------------------------------------------------

-- 007_audit_log.sql — every consequential admin/member action gets a row in
-- audit_log. Admins read it via /admin/audit. Inserts come from SECURITY DEFINER
-- RPCs (no INSERT policy needed). Builds the foundation for multi-admin governance
-- in Phase 3 (where pending approvals query this table too).

CREATE TABLE IF NOT EXISTS audit_log (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id    uuid REFERENCES profiles(id),
  action      text NOT NULL,
  target_type text,
  target_id   uuid,
  details     jsonb,
  at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_log_at_idx ON audit_log (at DESC);

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins read all audit rows" ON audit_log;
CREATE POLICY "Admins read all audit rows" ON audit_log FOR SELECT USING (is_admin());
GRANT SELECT ON audit_log TO authenticated;

-- ---------------------------------------------------------------------------
-- RPC updates: append audit_log INSERTs to the existing approval / rejection /
-- fee-generation / self-update RPCs. Body is otherwise unchanged from migration
-- 005 (plus the pool + contribution caps already in approve_loan).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_submission(p_submission_id uuid, p_amount_received numeric)
RETURNS void AS $$
DECLARE
  s         payment_submissions%ROWTYPE;
  v_base    numeric(12,2);
  v_penalty numeric(12,2);
  v_loan_id uuid;
  v_open    int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_amount_received IS NULL OR p_amount_received < 0
                                THEN RAISE EXCEPTION 'Invalid amount received'; END IF;

  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id FOR UPDATE;
  IF s.id IS NULL          THEN RAISE EXCEPTION 'Submission not found'; END IF;
  IF s.status <> 'pending' THEN RAISE EXCEPTION 'Already reviewed';    END IF;

  UPDATE payment_submissions
    SET status = 'approved', reviewed_at = now(), reviewed_by = auth.uid()
    WHERE id = p_submission_id;

  IF s.submission_type = 'monthly_fee' THEN
    SELECT amount INTO v_base FROM monthly_fees WHERE id = s.related_id;
    v_penalty := greatest(0, p_amount_received - COALESCE(v_base, 0));
    UPDATE monthly_fees
      SET status = 'paid', paid_at = now(), reviewed_by = auth.uid(),
          penalty_collected = v_penalty
      WHERE id = s.related_id;

  ELSIF s.submission_type = 'loan_installment' THEN
    SELECT total_due INTO v_base FROM loan_installments WHERE id = s.related_id;
    v_penalty := greatest(0, p_amount_received - COALESCE(v_base, 0));
    UPDATE loan_installments
      SET status = 'paid', paid_at = now(), reviewed_by = auth.uid(),
          penalty_collected = v_penalty
      WHERE id = s.related_id
      RETURNING loan_id INTO v_loan_id;

    SELECT COUNT(*) INTO v_open
      FROM loan_installments WHERE loan_id = v_loan_id AND status <> 'paid';
    IF v_open = 0 THEN
      UPDATE loans SET status = 'closed' WHERE id = v_loan_id;
    END IF;

  ELSE
    UPDATE payment_submissions SET amount_claimed = p_amount_received
      WHERE id = p_submission_id;
  END IF;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_submission', 'submission', p_submission_id,
          jsonb_build_object(
            'submission_type', s.submission_type,
            'member_id', s.member_id,
            'amount_received', p_amount_received
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION approve_loan(p_loan_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_loan         loans%ROWTYPE;
  v_int          numeric(12,2);
  v_pool         numeric(14,2);
  v_contribution numeric(14,2);
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL          THEN RAISE EXCEPTION 'Loan not found';      END IF;
  IF v_loan.status <> 'pending' THEN RAISE EXCEPTION 'Loan is not pending'; END IF;

  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;
  IF v_loan.principal > floor(0.25 * COALESCE(v_pool, 0)) THEN
    RAISE EXCEPTION 'Loan exceeds 25%% of the group pool (max %).', floor(0.25 * COALESCE(v_pool, 0));
  END IF;

  SELECT
      COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                WHERE member_id = v_loan.member_id
                  AND submission_type = 'savings_deposit'
                  AND status = 'approved'), 0)
    + COALESCE((SELECT SUM(amount) FROM monthly_fees
                WHERE member_id = v_loan.member_id AND status = 'paid'), 0)
  INTO v_contribution;
  IF v_loan.principal > floor(3 * v_contribution) THEN
    RAISE EXCEPTION 'Loan exceeds 3x member contribution (max %).', floor(3 * v_contribution);
  END IF;

  v_int := round(v_loan.principal * 0.05);

  UPDATE loans
    SET status = 'active', approved_at = now(), approved_by = auth.uid(),
        disbursed_at = now(), disbursement_proof_url = p_proof_url
    WHERE id = p_loan_id;

  INSERT INTO loan_installments (loan_id, installment_number, due_date, principal_due, interest_due)
  VALUES
    (p_loan_id, 1, (today_eat() + INTERVAL '1 month')::date, 0,                v_int),
    (p_loan_id, 2, (today_eat() + INTERVAL '2 month')::date, 0,                v_int),
    (p_loan_id, 3, (today_eat() + INTERVAL '3 month')::date, v_loan.principal, v_int);

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_loan', 'loan', p_loan_id,
          jsonb_build_object(
            'member_id', v_loan.member_id,
            'principal', v_loan.principal
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION reject_submission(p_submission_id uuid, p_reason text)
RETURNS void AS $$
DECLARE
  s payment_submissions%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id;
  IF s.id IS NULL OR s.status <> 'pending' THEN RETURN; END IF;

  UPDATE payment_submissions
    SET status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid(),
        rejection_reason = p_reason
    WHERE id = p_submission_id AND status = 'pending';

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'reject_submission', 'submission', p_submission_id,
          jsonb_build_object(
            'submission_type', s.submission_type,
            'member_id', s.member_id,
            'reason', p_reason
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION reject_loan(p_loan_id uuid, p_reason text)
RETURNS void AS $$
DECLARE
  l loans%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO l FROM loans WHERE id = p_loan_id;
  IF l.id IS NULL OR l.status <> 'pending' THEN RETURN; END IF;

  UPDATE loans
    SET status = 'rejected', rejection_reason = p_reason
    WHERE id = p_loan_id AND status = 'pending';

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'reject_loan', 'loan', p_loan_id,
          jsonb_build_object(
            'member_id', l.member_id,
            'principal', l.principal,
            'reason', p_reason
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ensure_current_fees runs on every dashboard load; we only log when it actually
-- generates new fee rows, so the audit isn't flooded with no-op calls.
CREATE OR REPLACE FUNCTION ensure_current_fees()
RETURNS void AS $$
DECLARE
  v_period   date := date_trunc('month', today_eat())::date;
  v_inserted int;
BEGIN
  WITH inserted AS (
    INSERT INTO monthly_fees (member_id, period, amount, status)
    SELECT p.id, v_period, 10000, 'pending'
    FROM profiles p
    WHERE p.is_active = true
    ON CONFLICT (member_id, period) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO v_inserted FROM inserted;

  IF v_inserted > 0 THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'generate_monthly_fees', 'system', NULL,
            jsonb_build_object('period', v_period, 'count', v_inserted));
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION update_own_phone(p_phone text)
RETURNS void AS $$
DECLARE
  v_old text;
  v_new text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  v_new := NULLIF(trim(p_phone), '');
  SELECT phone_number INTO v_old FROM public.profiles WHERE id = auth.uid();
  UPDATE public.profiles SET phone_number = v_new WHERE id = auth.uid();

  IF v_old IS DISTINCT FROM v_new THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'update_phone', 'profile', auth.uid(),
            jsonb_build_object('old', v_old, 'new', v_new));
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 008_two_step_approvals.sql
-- ---------------------------------------------------------------------------

-- 008_two_step_approvals.sql — multi-admin governance (Phase 3).
--   * Every monetary approval requires 2 admins (or all admins, whichever is smaller).
--   * An admin cannot approve their own submission or loan.
--   * Not all admins may simultaneously hold active loans — at least one must
--     remain loan-free at any time.
--   * Tracking goes through dedicated approval tables so the audit trail of who
--     approved what is permanent and the PK prevents double-approval.

CREATE TABLE IF NOT EXISTS submission_approvals (
  submission_id   uuid NOT NULL REFERENCES payment_submissions(id) ON DELETE CASCADE,
  admin_id        uuid NOT NULL REFERENCES profiles(id),
  amount_received numeric(12,2) NOT NULL,
  approved_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (submission_id, admin_id)
);

CREATE TABLE IF NOT EXISTS loan_approvals (
  loan_id     uuid NOT NULL REFERENCES loans(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id),
  proof_url   text NOT NULL,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (loan_id, admin_id)
);

ALTER TABLE submission_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_approvals       ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read submission approvals" ON submission_approvals;
CREATE POLICY "Admins read submission approvals" ON submission_approvals FOR SELECT USING (is_admin());

DROP POLICY IF EXISTS "Admins read loan approvals" ON loan_approvals;
CREATE POLICY "Admins read loan approvals" ON loan_approvals FOR SELECT USING (is_admin());

GRANT SELECT ON submission_approvals, loan_approvals TO authenticated;

-- Required approvals = min(2, current active admin count). Falls back to 1 while
-- only one admin exists so the system stays usable during the transition; once a
-- second admin is promoted, every approval needs two signatures.
CREATE OR REPLACE FUNCTION required_approvals()
RETURNS int AS $$
  SELECT least(2, count(*)::int) FROM profiles WHERE role = 'admin' AND is_active = true;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;


-- ---------------------------------------------------------------------------
-- approve_submission — 2-of-N, self-approval blocked, first admin's amount wins.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION approve_submission(p_submission_id uuid, p_amount_received numeric)
RETURNS void AS $$
DECLARE
  s              payment_submissions%ROWTYPE;
  v_base         numeric(12,2);
  v_penalty      numeric(12,2);
  v_loan_id      uuid;
  v_open         int;
  v_required     int;
  v_approvals    int;
  v_final_amount numeric(12,2);
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_amount_received IS NULL OR p_amount_received < 0
                                THEN RAISE EXCEPTION 'Invalid amount received'; END IF;

  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id FOR UPDATE;
  IF s.id IS NULL             THEN RAISE EXCEPTION 'Submission not found'; END IF;
  IF s.status <> 'pending'    THEN RAISE EXCEPTION 'Already reviewed';    END IF;
  IF s.member_id = auth.uid() THEN RAISE EXCEPTION 'Cannot approve your own submission'; END IF;

  BEGIN
    INSERT INTO submission_approvals (submission_id, admin_id, amount_received)
    VALUES (p_submission_id, auth.uid(), p_amount_received);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this submission';
  END;

  v_required := required_approvals();
  SELECT count(*) INTO v_approvals FROM submission_approvals WHERE submission_id = p_submission_id;

  -- Below threshold: still pending, log a partial approval and exit.
  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_submission', 'submission', p_submission_id,
            jsonb_build_object(
              'submission_type', s.submission_type,
              'member_id',       s.member_id,
              'amount_received', p_amount_received,
              'approvals',       v_approvals,
              'required',        v_required
            ));
    RETURN;
  END IF;

  -- Threshold reached → finalize using the FIRST approval's amount_received.
  SELECT amount_received INTO v_final_amount
  FROM submission_approvals
  WHERE submission_id = p_submission_id
  ORDER BY approved_at ASC
  LIMIT 1;

  UPDATE payment_submissions
    SET status = 'approved', reviewed_at = now(), reviewed_by = auth.uid()
    WHERE id = p_submission_id;

  IF s.submission_type = 'monthly_fee' THEN
    SELECT amount INTO v_base FROM monthly_fees WHERE id = s.related_id;
    v_penalty := greatest(0, v_final_amount - COALESCE(v_base, 0));
    UPDATE monthly_fees
      SET status = 'paid', paid_at = now(), reviewed_by = auth.uid(),
          penalty_collected = v_penalty
      WHERE id = s.related_id;

  ELSIF s.submission_type = 'loan_installment' THEN
    SELECT total_due INTO v_base FROM loan_installments WHERE id = s.related_id;
    v_penalty := greatest(0, v_final_amount - COALESCE(v_base, 0));
    UPDATE loan_installments
      SET status = 'paid', paid_at = now(), reviewed_by = auth.uid(),
          penalty_collected = v_penalty
      WHERE id = s.related_id
      RETURNING loan_id INTO v_loan_id;

    SELECT COUNT(*) INTO v_open
      FROM loan_installments WHERE loan_id = v_loan_id AND status <> 'paid';
    IF v_open = 0 THEN
      UPDATE loans SET status = 'closed' WHERE id = v_loan_id;
    END IF;

  ELSE
    UPDATE payment_submissions SET amount_claimed = v_final_amount
      WHERE id = p_submission_id;
  END IF;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_submission', 'submission', p_submission_id,
          jsonb_build_object(
            'submission_type', s.submission_type,
            'member_id',       s.member_id,
            'amount_received', v_final_amount,
            'approvals',       v_approvals
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ---------------------------------------------------------------------------
-- approve_loan — 2-of-N, self-approval blocked, admin-loan restriction enforced
-- at the moment the loan would go active.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION approve_loan(p_loan_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_loan              loans%ROWTYPE;
  v_int               numeric(12,2);
  v_pool              numeric(14,2);
  v_contribution      numeric(14,2);
  v_required          int;
  v_approvals         int;
  v_final_proof       text;
  v_other_admin_loans int;
  v_total_admins      int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL             THEN RAISE EXCEPTION 'Loan not found';      END IF;
  IF v_loan.status <> 'pending'    THEN RAISE EXCEPTION 'Loan is not pending'; END IF;
  IF v_loan.member_id = auth.uid() THEN RAISE EXCEPTION 'Cannot approve your own loan'; END IF;

  -- Caps re-validated on every approval attempt (state may have shifted since request).
  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;
  IF v_loan.principal > floor(0.25 * COALESCE(v_pool, 0)) THEN
    RAISE EXCEPTION 'Loan exceeds 25%% of the group pool (max %).', floor(0.25 * COALESCE(v_pool, 0));
  END IF;

  SELECT
      COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                WHERE member_id = v_loan.member_id
                  AND submission_type = 'savings_deposit'
                  AND status = 'approved'), 0)
    + COALESCE((SELECT SUM(amount) FROM monthly_fees
                WHERE member_id = v_loan.member_id AND status = 'paid'), 0)
  INTO v_contribution;
  IF v_loan.principal > floor(3 * v_contribution) THEN
    RAISE EXCEPTION 'Loan exceeds 3x member contribution (max %).', floor(3 * v_contribution);
  END IF;

  BEGIN
    INSERT INTO loan_approvals (loan_id, admin_id, proof_url)
    VALUES (p_loan_id, auth.uid(), p_proof_url);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this loan';
  END;

  v_required := required_approvals();
  SELECT count(*) INTO v_approvals FROM loan_approvals WHERE loan_id = p_loan_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_loan', 'loan', p_loan_id,
            jsonb_build_object(
              'member_id', v_loan.member_id,
              'principal', v_loan.principal,
              'approvals', v_approvals,
              'required',  v_required
            ));
    RETURN;
  END IF;

  -- Threshold reached → about to activate the loan.
  -- Admin-loan restriction: at most N-1 admins may simultaneously hold active loans.
  IF (SELECT role FROM profiles WHERE id = v_loan.member_id) = 'admin' THEN
    SELECT count(*) INTO v_total_admins
      FROM profiles WHERE role = 'admin' AND is_active = true;
    SELECT count(*) INTO v_other_admin_loans
      FROM loans
      WHERE status = 'active'
        AND member_id IN (SELECT id FROM profiles WHERE role = 'admin' AND is_active = true)
        AND member_id <> v_loan.member_id;
    IF v_other_admin_loans >= v_total_admins - 1 THEN
      RAISE EXCEPTION 'Not all admins may hold loans simultaneously; one admin must remain loan-free.';
    END IF;
  END IF;

  SELECT proof_url INTO v_final_proof
  FROM loan_approvals WHERE loan_id = p_loan_id
  ORDER BY approved_at ASC LIMIT 1;

  v_int := round(v_loan.principal * 0.05);

  UPDATE loans
    SET status = 'active', approved_at = now(), approved_by = auth.uid(),
        disbursed_at = now(), disbursement_proof_url = v_final_proof
    WHERE id = p_loan_id;

  INSERT INTO loan_installments (loan_id, installment_number, due_date, principal_due, interest_due)
  VALUES
    (p_loan_id, 1, (today_eat() + INTERVAL '1 month')::date, 0,                v_int),
    (p_loan_id, 2, (today_eat() + INTERVAL '2 month')::date, 0,                v_int),
    (p_loan_id, 3, (today_eat() + INTERVAL '3 month')::date, v_loan.principal, v_int);

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_loan', 'loan', p_loan_id,
          jsonb_build_object(
            'member_id', v_loan.member_id,
            'principal', v_loan.principal,
            'approvals', v_approvals
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ---------------------------------------------------------------------------
-- 009_notifications.sql
-- ---------------------------------------------------------------------------

-- 009_notifications.sql — in-app notifications (Phase 4).
-- Triggers insert a row per recipient when something they care about happens:
--   * Member's submission / loan changes status (approved, rejected, loan active/closed)
--   * Admin queue: a new pending submission or loan arrives
-- Members read & dismiss their own rows; the bell + realtime subscription in the
-- frontend surfaces the count without polling.

CREATE TABLE IF NOT EXISTS notifications (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  kind         text NOT NULL,
  title        text NOT NULL,
  body         text,
  data         jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  read_at      timestamptz
);

CREATE INDEX IF NOT EXISTS notifications_recipient_idx
  ON notifications (recipient_id, created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_unread_idx
  ON notifications (recipient_id) WHERE read_at IS NULL;

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Members read own notifications" ON notifications;
CREATE POLICY "Members read own notifications" ON notifications FOR SELECT
  USING (recipient_id = auth.uid());

DROP POLICY IF EXISTS "Members mark own notifications" ON notifications;
CREATE POLICY "Members mark own notifications" ON notifications FOR UPDATE
  USING (recipient_id = auth.uid())
  WITH CHECK (recipient_id = auth.uid());

GRANT SELECT, UPDATE ON notifications TO authenticated;

-- ---------------------------------------------------------------------------
-- Trigger: payment_submissions status change → notify the member
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION notify_on_submission_change()
RETURNS trigger AS $$
DECLARE
  v_type_label text;
BEGIN
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;

  v_type_label := CASE NEW.submission_type
    WHEN 'savings_deposit'  THEN 'savings deposit'
    WHEN 'monthly_fee'      THEN 'monthly fee'
    WHEN 'loan_installment' THEN 'loan repayment'
    ELSE NEW.submission_type
  END;

  IF NEW.status = 'approved' THEN
    INSERT INTO notifications (recipient_id, kind, title, body, data)
    VALUES (NEW.member_id, 'submission_approved',
            'Payment approved',
            'Your ' || v_type_label || ' was approved.',
            jsonb_build_object('submission_id', NEW.id, 'amount', NEW.amount_claimed));
  ELSIF NEW.status = 'rejected' THEN
    INSERT INTO notifications (recipient_id, kind, title, body, data)
    VALUES (NEW.member_id, 'submission_rejected',
            'Payment rejected',
            COALESCE(NEW.rejection_reason, 'Your ' || v_type_label || ' was rejected.'),
            jsonb_build_object('submission_id', NEW.id));
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS on_submission_status_change ON payment_submissions;
CREATE TRIGGER on_submission_status_change
  AFTER UPDATE OF status ON payment_submissions
  FOR EACH ROW EXECUTE FUNCTION notify_on_submission_change();

-- ---------------------------------------------------------------------------
-- Trigger: loan status change → notify the borrower
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION notify_on_loan_change()
RETURNS trigger AS $$
DECLARE
  v_kind  text;
  v_title text;
  v_body  text;
BEGIN
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;

  IF NEW.status = 'active' THEN
    v_kind  := 'loan_active';
    v_title := 'Loan approved';
    v_body  := 'Your loan has been disbursed. Repayment schedule is in your dashboard.';
  ELSIF NEW.status = 'rejected' THEN
    v_kind  := 'loan_rejected';
    v_title := 'Loan request rejected';
    v_body  := COALESCE(NEW.rejection_reason, 'Your loan request was rejected.');
  ELSIF NEW.status = 'closed' THEN
    v_kind  := 'loan_closed';
    v_title := 'Loan fully repaid';
    v_body  := 'Congratulations — your loan has been fully repaid.';
  ELSE
    RETURN NEW;
  END IF;

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (NEW.member_id, v_kind, v_title, v_body,
          jsonb_build_object('loan_id', NEW.id, 'principal', NEW.principal));
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS on_loan_status_change ON loans;
CREATE TRIGGER on_loan_status_change
  AFTER UPDATE OF status ON loans
  FOR EACH ROW EXECUTE FUNCTION notify_on_loan_change();

-- ---------------------------------------------------------------------------
-- Trigger: new pending submission → notify every active admin
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION notify_admins_on_new_submission()
RETURNS trigger AS $$
DECLARE
  v_member_name text;
BEGIN
  SELECT full_name INTO v_member_name FROM profiles WHERE id = NEW.member_id;
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'new_submission',
         'New payment to review',
         COALESCE(v_member_name, 'A member') || ' submitted a ' || NEW.submission_type ||
           ' for ' || NEW.amount_claimed || ' TZS',
         jsonb_build_object('submission_id', NEW.id, 'member_id', NEW.member_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS on_new_submission ON payment_submissions;
CREATE TRIGGER on_new_submission
  AFTER INSERT ON payment_submissions
  FOR EACH ROW EXECUTE FUNCTION notify_admins_on_new_submission();

-- ---------------------------------------------------------------------------
-- Trigger: new pending loan → notify every active admin
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION notify_admins_on_new_loan()
RETURNS trigger AS $$
DECLARE
  v_member_name text;
BEGIN
  SELECT full_name INTO v_member_name FROM profiles WHERE id = NEW.member_id;
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'new_loan',
         'New loan request',
         COALESCE(v_member_name, 'A member') || ' requested ' || NEW.principal || ' TZS',
         jsonb_build_object('loan_id', NEW.id, 'member_id', NEW.member_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS on_new_loan ON loans;
CREATE TRIGGER on_new_loan
  AFTER INSERT ON loans
  FOR EACH ROW EXECUTE FUNCTION notify_admins_on_new_loan();

-- ---------------------------------------------------------------------------
-- 010_member_deletion.sql
-- ---------------------------------------------------------------------------

-- 010_member_deletion.sql — 2-of-N member deletion governance.
-- Mirrors the approval pattern from migration 008:
--   * An admin opens a deletion request for another member (cannot target self).
--   * Their request auto-records as their approval (1/2).
--   * A second admin approves → execute_member_deletion runs in the same
--     transaction: snapshots the member into audit_log, nulls out FK
--     references in OTHER members' history (preserves their records), deletes
--     the target's own rows (loans/installments cascade), and finally deletes
--     the auth user (which cascades to profiles → deletion_requests →
--     deletion_approvals → notifications).
-- Guard: the last remaining admin cannot be deleted, so the group never ends
-- up admin-less.

CREATE TABLE IF NOT EXISTS deletion_requests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_member_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  -- Snapshot so audit history survives even after the cascade clears the row.
  target_snapshot  jsonb,
  requested_by     uuid REFERENCES profiles(id) ON DELETE SET NULL,
  reason           text,
  status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'approved', 'cancelled')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  executed_at      timestamptz
);
CREATE INDEX IF NOT EXISTS deletion_requests_status_idx
  ON deletion_requests (status, created_at DESC);

CREATE TABLE IF NOT EXISTS deletion_approvals (
  request_id  uuid NOT NULL REFERENCES deletion_requests(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, admin_id)
);

ALTER TABLE deletion_requests  ENABLE ROW LEVEL SECURITY;
ALTER TABLE deletion_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read deletion requests" ON deletion_requests;
CREATE POLICY "Admins read deletion requests" ON deletion_requests FOR SELECT USING (is_admin());

DROP POLICY IF EXISTS "Admins read deletion approvals" ON deletion_approvals;
CREATE POLICY "Admins read deletion approvals" ON deletion_approvals FOR SELECT USING (is_admin());

GRANT SELECT ON deletion_requests, deletion_approvals TO authenticated;

-- ---------------------------------------------------------------------------
-- Internal: actually wipe the member. Called from request_/approve_ once the
-- approval threshold is reached. Marked SECURITY DEFINER so it can touch
-- auth.users; never call directly from the client.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION execute_member_deletion(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request                 deletion_requests%ROWTYPE;
  v_target_id               uuid;
  v_snapshot                jsonb;
  v_remaining_admin_count   int;
  v_target_role             text;
BEGIN
  SELECT * INTO v_request FROM deletion_requests WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Deletion request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';          END IF;

  v_target_id := v_request.target_member_id;
  v_snapshot  := v_request.target_snapshot;

  SELECT role INTO v_target_role FROM profiles WHERE id = v_target_id;
  -- Re-check the last-admin guard at execution time.
  IF v_target_role = 'admin' THEN
    SELECT count(*) INTO v_remaining_admin_count
      FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_target_id;
    IF v_remaining_admin_count < 1 THEN
      RAISE EXCEPTION 'Cannot delete the last remaining admin';
    END IF;
  END IF;

  -- Snapshot to audit_log BEFORE the cascade clears related rows.
  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'execute_member_deletion', 'profile', v_target_id,
          COALESCE(v_snapshot, '{}'::jsonb)
            || jsonb_build_object('request_id', p_request_id, 'role', v_target_role));

  -- Mark request approved BEFORE the cascade kills it.
  UPDATE deletion_requests
     SET status = 'approved', executed_at = now()
   WHERE id = p_request_id;

  -- Null out FK references in OTHER members' records (preserves their history).
  UPDATE monthly_fees        SET reviewed_by = NULL WHERE reviewed_by = v_target_id;
  UPDATE loans               SET approved_by = NULL WHERE approved_by = v_target_id;
  UPDATE payment_submissions SET reviewed_by = NULL WHERE reviewed_by = v_target_id;
  UPDATE loan_installments   SET reviewed_by = NULL WHERE reviewed_by = v_target_id;
  UPDATE audit_log           SET actor_id    = NULL WHERE actor_id    = v_target_id;
  UPDATE deletion_requests   SET requested_by = NULL WHERE requested_by = v_target_id;

  -- Clean the target's votes in approval tables (avoids FK violation on profile delete).
  DELETE FROM submission_approvals WHERE admin_id = v_target_id;
  DELETE FROM loan_approvals       WHERE admin_id = v_target_id;
  -- deletion_approvals.admin_id cascades on profile delete.

  -- Delete the target's own records. loans cascades to loan_installments and
  -- payment_submissions cascades to submission_approvals.
  DELETE FROM loans              WHERE member_id = v_target_id;
  DELETE FROM payment_submissions WHERE member_id = v_target_id;
  DELETE FROM monthly_fees       WHERE member_id = v_target_id;
  -- notifications cascades via recipient_id ON DELETE CASCADE.

  -- Finally the auth user. Cascades to profiles, and via profiles to
  -- notifications/deletion_requests/deletion_approvals (including this request).
  DELETE FROM auth.users WHERE id = v_target_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ---------------------------------------------------------------------------
-- Public: an admin opens a deletion request. Auto-records the requester's
-- approval. If only one admin is required (single-admin transition), executes
-- immediately. Notifies the other admins so they can vote.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION request_member_deletion(p_target_member_id uuid, p_reason text DEFAULT NULL)
RETURNS uuid AS $$
DECLARE
  v_request_id    uuid;
  v_target        profiles%ROWTYPE;
  v_target_email  text;
  v_admin_count   int;
  v_required      int;
  v_requester_name text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_target_member_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot request your own deletion';
  END IF;

  SELECT * INTO v_target FROM profiles WHERE id = p_target_member_id;
  IF v_target.id IS NULL THEN RAISE EXCEPTION 'Member not found'; END IF;

  -- Don't allow deleting the last remaining admin.
  IF v_target.role = 'admin' THEN
    SELECT count(*) INTO v_admin_count
      FROM profiles WHERE role = 'admin' AND is_active = true;
    IF v_admin_count <= 1 THEN
      RAISE EXCEPTION 'Cannot delete the last remaining admin';
    END IF;
  END IF;

  -- Prevent overlapping pending requests for the same target.
  IF EXISTS (
    SELECT 1 FROM deletion_requests
     WHERE target_member_id = p_target_member_id AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A pending deletion request already exists for this member';
  END IF;

  SELECT email INTO v_target_email FROM auth.users WHERE id = p_target_member_id;
  SELECT full_name INTO v_requester_name FROM profiles WHERE id = auth.uid();

  INSERT INTO deletion_requests (target_member_id, target_snapshot, requested_by, reason)
  VALUES (p_target_member_id,
          jsonb_build_object(
            'full_name',    v_target.full_name,
            'email',        v_target_email,
            'phone_number', v_target.phone_number,
            'role',         v_target.role
          ),
          auth.uid(),
          p_reason)
  RETURNING id INTO v_request_id;

  -- Auto-record requester's vote.
  INSERT INTO deletion_approvals (request_id, admin_id) VALUES (v_request_id, auth.uid());

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_member_deletion', 'profile', p_target_member_id,
          jsonb_build_object(
            'request_id', v_request_id,
            'reason',     p_reason,
            'target_name', v_target.full_name
          ));

  -- Notify every OTHER active admin so they can act.
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'deletion_requested',
         'Member deletion requested',
         COALESCE(v_requester_name, 'An admin') || ' wants to delete ' || v_target.full_name,
         jsonb_build_object(
           'request_id', v_request_id,
           'target_id',  p_target_member_id
         )
  FROM profiles p
  WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  -- If only one admin is required (single-admin transition), execute immediately.
  v_required := required_approvals();
  IF v_required <= 1 THEN
    PERFORM execute_member_deletion(v_request_id);
  END IF;

  RETURN v_request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ---------------------------------------------------------------------------
-- Public: a second admin approves. Reaches the threshold → execute.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION approve_member_deletion(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request   deletion_requests%ROWTYPE;
  v_approvals int;
  v_required  int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM deletion_requests WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Deletion request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed';   END IF;
  IF v_request.target_member_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own deletion';
  END IF;

  BEGIN
    INSERT INTO deletion_approvals (request_id, admin_id) VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this deletion';
  END;

  v_required := required_approvals();
  SELECT count(*) INTO v_approvals FROM deletion_approvals WHERE request_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_member_deletion', 'profile',
            v_request.target_member_id,
            jsonb_build_object(
              'request_id', p_request_id,
              'approvals',  v_approvals,
              'required',   v_required
            ));
    RETURN;
  END IF;

  -- Threshold reached → execute deletion.
  PERFORM execute_member_deletion(p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ---------------------------------------------------------------------------
-- Public: any admin can cancel a still-pending deletion request.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cancel_member_deletion(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request deletion_requests%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM deletion_requests WHERE id = p_request_id;
  IF v_request.id IS NULL OR v_request.status <> 'pending' THEN
    RETURN;
  END IF;

  UPDATE deletion_requests SET status = 'cancelled' WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_member_deletion', 'profile', v_request.target_member_id,
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 011_flexible_repayment.sql
-- ---------------------------------------------------------------------------

-- 011_flexible_repayment.sql — flexible loan repayment + duplicate submission guard.
--
-- Loan model change:
--   * The 3-installment schedule is still generated at approval time, but it is
--     now a *projected* schedule based on the original principal.
--   * Each month the minimum payment is the interest on the CURRENT outstanding
--     principal (= outstanding_principal × 5%). Anything extra reduces principal.
--   * When a payment lands, the remaining pending installments' interest_due
--     (and installment-3's principal_due) are recomputed on the new outstanding.
--   * If a payment drops the outstanding to zero, the loan closes immediately
--     and the remaining unpaid installments are marked 'cancelled' so the
--     repayment history is preserved.
--
-- Duplicate submission guard:
--   * A member can have at most one PENDING submission per related obligation
--     (monthly_fees / loan_installments). Rejected ones don't count, so they
--     can fix and resubmit; approved ones flip the row to paid so the UI
--     hides it.
--   * Cannot submit against an obligation that is already 'paid' or 'cancelled'.

-- --------------------------------------------------------------------------
-- 1. Schema changes
-- --------------------------------------------------------------------------

ALTER TABLE loans
  ADD COLUMN IF NOT EXISTS outstanding_principal numeric(12,2) NOT NULL DEFAULT 0;

ALTER TABLE loan_installments
  ADD COLUMN IF NOT EXISTS principal_paid numeric(12,2) NOT NULL DEFAULT 0;

-- Allow 'cancelled' as a status (for installments superseded by early repayment).
ALTER TABLE loan_installments DROP CONSTRAINT IF EXISTS loan_installments_status_check;
ALTER TABLE loan_installments
  ADD CONSTRAINT loan_installments_status_check
  CHECK (status IN ('pending', 'paid', 'cancelled'));

-- Backfill outstanding_principal for any existing active loans. New rows go
-- through approve_loan which sets this correctly.
UPDATE loans
   SET outstanding_principal = principal
 WHERE status = 'active' AND outstanding_principal = 0;

-- --------------------------------------------------------------------------
-- 2. v_installment_status & v_installment_status_money — recognise the new
--    'cancelled' status and surface principal_paid via SELECT li.*. We DROP
--    and re-CREATE rather than CREATE OR REPLACE because adding
--    loan_installments.principal_paid shifts the column ordering, and
--    Postgres forbids that with CREATE OR REPLACE VIEW. v_installment_status
--    is dropped with CASCADE so the dependent v_installment_status_money is
--    also dropped; both are recreated and re-granted below.
-- --------------------------------------------------------------------------

DROP VIEW IF EXISTS v_installment_status_money;
DROP VIEW IF EXISTS v_installment_status CASCADE;

CREATE VIEW v_installment_status AS
SELECT
  li.*,
  CASE
    WHEN li.status = 'paid' OR li.status = 'cancelled' OR today_eat() <= li.due_date THEN 0
    ELSE (date_part('year',  age(today_eat(), li.due_date)) * 12
        + date_part('month', age(today_eat(), li.due_date)))::int + 1
  END AS penalty_months,
  CASE
    WHEN li.status = 'paid'        THEN 'paid'
    WHEN li.status = 'cancelled'   THEN 'cancelled'
    WHEN today_eat() > li.due_date THEN 'overdue'
    ELSE 'pending'
  END AS computed_status
FROM loan_installments li;

CREATE VIEW v_installment_status_money AS
SELECT
  i.*,
  round(0.05 * i.total_due * i.penalty_months)               AS penalty_due,
  i.total_due + round(0.05 * i.total_due * i.penalty_months) AS total_with_penalty
FROM v_installment_status i;

-- Re-grant SELECT (dropped along with the views).
GRANT SELECT ON v_installment_status, v_installment_status_money TO authenticated;

-- --------------------------------------------------------------------------
-- 3. Trigger: prevent duplicate / late submissions at the DB level
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION validate_payment_submission()
RETURNS trigger AS $$
DECLARE
  v_fee_status         text;
  v_inst_status        text;
BEGIN
  IF NEW.submission_type IN ('monthly_fee', 'loan_installment')
     AND NEW.related_id IS NOT NULL THEN
    -- Reject if a pending submission already exists for the same related row.
    IF EXISTS (
      SELECT 1 FROM payment_submissions
       WHERE submission_type = NEW.submission_type
         AND related_id      = NEW.related_id
         AND status          = 'pending'
         AND id <> NEW.id
    ) THEN
      RAISE EXCEPTION USING
        ERRCODE = 'unique_violation',
        MESSAGE = 'A pending payment for this item is already under review.';
    END IF;

    -- Reject if the related obligation is already settled.
    IF NEW.submission_type = 'monthly_fee' THEN
      SELECT status INTO v_fee_status FROM monthly_fees WHERE id = NEW.related_id;
      IF v_fee_status = 'paid' THEN
        RAISE EXCEPTION 'This monthly fee is already paid.';
      END IF;
    ELSIF NEW.submission_type = 'loan_installment' THEN
      SELECT status INTO v_inst_status FROM loan_installments WHERE id = NEW.related_id;
      IF v_inst_status IN ('paid', 'cancelled') THEN
        RAISE EXCEPTION 'This installment is no longer outstanding.';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS payment_submission_validate ON payment_submissions;
CREATE TRIGGER payment_submission_validate
  BEFORE INSERT ON payment_submissions
  FOR EACH ROW EXECUTE FUNCTION validate_payment_submission();

-- --------------------------------------------------------------------------
-- 4. approve_loan — also set outstanding_principal = principal
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_loan(p_loan_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_loan              loans%ROWTYPE;
  v_int               numeric(12,2);
  v_pool              numeric(14,2);
  v_contribution      numeric(14,2);
  v_required          int;
  v_approvals         int;
  v_final_proof       text;
  v_other_admin_loans int;
  v_total_admins      int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL             THEN RAISE EXCEPTION 'Loan not found';      END IF;
  IF v_loan.status <> 'pending'    THEN RAISE EXCEPTION 'Loan is not pending'; END IF;
  IF v_loan.member_id = auth.uid() THEN RAISE EXCEPTION 'Cannot approve your own loan'; END IF;

  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;
  IF v_loan.principal > floor(0.25 * COALESCE(v_pool, 0)) THEN
    RAISE EXCEPTION 'Loan exceeds 25%% of the group pool (max %).', floor(0.25 * COALESCE(v_pool, 0));
  END IF;

  SELECT
      COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                WHERE member_id = v_loan.member_id
                  AND submission_type = 'savings_deposit'
                  AND status = 'approved'), 0)
    + COALESCE((SELECT SUM(amount) FROM monthly_fees
                WHERE member_id = v_loan.member_id AND status = 'paid'), 0)
  INTO v_contribution;
  IF v_loan.principal > floor(3 * v_contribution) THEN
    RAISE EXCEPTION 'Loan exceeds 3x member contribution (max %).', floor(3 * v_contribution);
  END IF;

  BEGIN
    INSERT INTO loan_approvals (loan_id, admin_id, proof_url)
    VALUES (p_loan_id, auth.uid(), p_proof_url);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this loan';
  END;

  v_required := required_approvals();
  SELECT count(*) INTO v_approvals FROM loan_approvals WHERE loan_id = p_loan_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_loan', 'loan', p_loan_id,
            jsonb_build_object(
              'member_id', v_loan.member_id,
              'principal', v_loan.principal,
              'approvals', v_approvals,
              'required',  v_required
            ));
    RETURN;
  END IF;

  -- Admin-loan restriction.
  IF (SELECT role FROM profiles WHERE id = v_loan.member_id) = 'admin' THEN
    SELECT count(*) INTO v_total_admins
      FROM profiles WHERE role = 'admin' AND is_active = true;
    SELECT count(*) INTO v_other_admin_loans
      FROM loans
      WHERE status = 'active'
        AND member_id IN (SELECT id FROM profiles WHERE role = 'admin' AND is_active = true)
        AND member_id <> v_loan.member_id;
    IF v_other_admin_loans >= v_total_admins - 1 THEN
      RAISE EXCEPTION 'Not all admins may hold loans simultaneously; one admin must remain loan-free.';
    END IF;
  END IF;

  SELECT proof_url INTO v_final_proof
  FROM loan_approvals WHERE loan_id = p_loan_id
  ORDER BY approved_at ASC LIMIT 1;

  v_int := round(v_loan.principal * 0.05);

  -- Activate the loan and initialize outstanding_principal.
  UPDATE loans
    SET status = 'active',
        approved_at = now(),
        approved_by = auth.uid(),
        disbursed_at = now(),
        disbursement_proof_url = v_final_proof,
        outstanding_principal = v_loan.principal
    WHERE id = p_loan_id;

  INSERT INTO loan_installments (loan_id, installment_number, due_date, principal_due, interest_due)
  VALUES
    (p_loan_id, 1, (today_eat() + INTERVAL '1 month')::date, 0,                v_int),
    (p_loan_id, 2, (today_eat() + INTERVAL '2 month')::date, 0,                v_int),
    (p_loan_id, 3, (today_eat() + INTERVAL '3 month')::date, v_loan.principal, v_int);

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_loan', 'loan', p_loan_id,
          jsonb_build_object(
            'member_id', v_loan.member_id,
            'principal', v_loan.principal,
            'approvals', v_approvals
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- --------------------------------------------------------------------------
-- 5. approve_submission — dynamic principal repayment + cancel-on-full-repay
--    + recalc of remaining installments' interest based on new outstanding.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_submission(p_submission_id uuid, p_amount_received numeric)
RETURNS void AS $$
DECLARE
  s                payment_submissions%ROWTYPE;
  v_base           numeric(12,2);
  v_penalty        numeric(12,2);
  v_loan_id        uuid;
  v_open           int;
  v_required       int;
  v_approvals      int;
  v_final_amount   numeric(12,2);
  v_inst           loan_installments%ROWTYPE;
  v_principal_paid numeric(12,2);
  v_outstanding    numeric(12,2);
  v_new_int        numeric(12,2);
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_amount_received IS NULL OR p_amount_received < 0
                                THEN RAISE EXCEPTION 'Invalid amount received'; END IF;

  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id FOR UPDATE;
  IF s.id IS NULL             THEN RAISE EXCEPTION 'Submission not found'; END IF;
  IF s.status <> 'pending'    THEN RAISE EXCEPTION 'Already reviewed';    END IF;
  IF s.member_id = auth.uid() THEN RAISE EXCEPTION 'Cannot approve your own submission'; END IF;

  BEGIN
    INSERT INTO submission_approvals (submission_id, admin_id, amount_received)
    VALUES (p_submission_id, auth.uid(), p_amount_received);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this submission';
  END;

  v_required := required_approvals();
  SELECT count(*) INTO v_approvals FROM submission_approvals WHERE submission_id = p_submission_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_submission', 'submission', p_submission_id,
            jsonb_build_object(
              'submission_type', s.submission_type,
              'member_id',       s.member_id,
              'amount_received', p_amount_received,
              'approvals',       v_approvals,
              'required',        v_required
            ));
    RETURN;
  END IF;

  -- Threshold reached → finalize using the FIRST approval's amount_received.
  SELECT amount_received INTO v_final_amount
  FROM submission_approvals
  WHERE submission_id = p_submission_id
  ORDER BY approved_at ASC
  LIMIT 1;

  UPDATE payment_submissions
    SET status = 'approved', reviewed_at = now(), reviewed_by = auth.uid()
    WHERE id = p_submission_id;

  IF s.submission_type = 'monthly_fee' THEN
    SELECT amount INTO v_base FROM monthly_fees WHERE id = s.related_id;
    v_penalty := greatest(0, v_final_amount - COALESCE(v_base, 0));
    UPDATE monthly_fees
      SET status = 'paid', paid_at = now(), reviewed_by = auth.uid(),
          penalty_collected = v_penalty
      WHERE id = s.related_id;

  ELSIF s.submission_type = 'loan_installment' THEN
    -- Lock the installment, its loan, and split the payment into interest /
    -- penalty / principal portions.
    SELECT * INTO v_inst FROM loan_installments WHERE id = s.related_id FOR UPDATE;
    v_loan_id := v_inst.loan_id;

    -- Live penalty for this installment (5% × total_due × months overdue).
    SELECT COALESCE(penalty_due, 0) INTO v_penalty
      FROM v_installment_status_money WHERE id = v_inst.id;

    -- Enforce the "no partial payments" invariant: the member must cover the
    -- contracted total (interest + any principal_due) PLUS any accrued penalty.
    IF v_final_amount < v_inst.total_due + v_penalty THEN
      RAISE EXCEPTION 'Payment of % is below the required minimum % (% due + % penalty).',
        v_final_amount, v_inst.total_due + v_penalty, v_inst.total_due, v_penalty;
    END IF;

    -- Anything paid above the minimum reduces outstanding principal beyond the
    -- contracted principal_due (which is 0 for installments 1/2, and the full
    -- remaining outstanding for installment 3).
    SELECT outstanding_principal INTO v_outstanding FROM loans WHERE id = v_loan_id FOR UPDATE;
    v_principal_paid := v_inst.principal_due + (v_final_amount - v_inst.total_due - v_penalty);
    IF v_principal_paid > v_outstanding THEN
      v_principal_paid := v_outstanding;
    END IF;

    UPDATE loan_installments
      SET status = 'paid',
          paid_at = now(),
          reviewed_by = auth.uid(),
          penalty_collected = v_penalty,
          principal_paid = v_principal_paid
      WHERE id = v_inst.id;

    v_outstanding := v_outstanding - v_principal_paid;

    UPDATE loans SET outstanding_principal = v_outstanding WHERE id = v_loan_id;

    IF v_outstanding <= 0 THEN
      -- Loan fully repaid → close it and cancel any remaining unpaid installments.
      UPDATE loans SET status = 'closed' WHERE id = v_loan_id;
      UPDATE loan_installments
        SET status = 'cancelled'
        WHERE loan_id = v_loan_id AND status = 'pending';
    ELSE
      -- Recalculate remaining pending installments based on the new outstanding.
      -- Installments 1 and 2: interest only, principal_due = 0.
      -- Installment 3: must clear the remaining principal.
      v_new_int := round(v_outstanding * 0.05);
      UPDATE loan_installments
         SET interest_due = v_new_int,
             principal_due = CASE WHEN installment_number = 3 THEN v_outstanding ELSE 0 END
       WHERE loan_id = v_loan_id
         AND status = 'pending';

      -- Safety net: if for some reason no pending installments remain but
      -- outstanding > 0, leave the loan open — the admin will need to handle
      -- it explicitly.
      SELECT COUNT(*) INTO v_open
        FROM loan_installments WHERE loan_id = v_loan_id AND status = 'pending';
      IF v_open = 0 AND v_outstanding = 0 THEN
        UPDATE loans SET status = 'closed' WHERE id = v_loan_id;
      END IF;
    END IF;

  ELSE
    UPDATE payment_submissions SET amount_claimed = v_final_amount
      WHERE id = p_submission_id;
  END IF;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_submission', 'submission', p_submission_id,
          jsonb_build_object(
            'submission_type', s.submission_type,
            'member_id',       s.member_id,
            'amount_received', v_final_amount,
            'approvals',       v_approvals
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ---------------------------------------------------------------------------
-- 012_group_assets.sql
-- ---------------------------------------------------------------------------

-- 012_group_assets.sql — total group assets view.
--
-- v_group_pool is liquid cash (loanable balance) — it already subtracts every
-- active/closed loan's principal. The "total group assets" answers the broader
-- question: what is the group worth in total? That is the liquid pool PLUS
-- everything still owed back by active borrowers (outstanding_principal).
--
-- Returned columns:
--   pool_balance_tzs      — same as v_group_pool.pool_balance_tzs (liquid cash)
--   outstanding_loans_tzs — sum of outstanding_principal for active loans
--   total_assets_tzs      — pool + outstanding loans (the group's net wealth)

CREATE OR REPLACE VIEW v_group_assets AS
SELECT
  (SELECT pool_balance_tzs FROM v_group_pool) AS pool_balance_tzs,
  COALESCE(
    (SELECT SUM(outstanding_principal) FROM loans WHERE status = 'active'),
    0
  ) AS outstanding_loans_tzs,
  (SELECT pool_balance_tzs FROM v_group_pool) +
    COALESCE(
      (SELECT SUM(outstanding_principal) FROM loans WHERE status = 'active'),
      0
    ) AS total_assets_tzs;

GRANT SELECT ON v_group_assets TO authenticated;

-- ---------------------------------------------------------------------------
-- 013_savings_edits.sql
-- ---------------------------------------------------------------------------

-- 013_savings_edits.sql — 2-of-N savings adjustments.
--
-- An admin can open a request to adjust any member's savings by a positive or
-- negative delta, BUT cannot target another admin's account. Admins MAY target
-- their own savings. The requester's own vote does NOT count toward the
-- approval threshold ("the other admins must approve"); two admins other than
-- the requester must approve before the adjustment is applied.
--
-- The pool view (v_group_pool) is extended to include applied adjustments so
-- corrections to a member's savings flow through to the group's loanable balance.
--
-- Rule summary at execution:
--   * delta is added to the target's effective savings total (a corrective entry).
--   * Audit + notification trail records who requested, who approved, and the
--     reason. The target gets a notification when the change applies.

-- --------------------------------------------------------------------------
-- 1. Schema
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS savings_adjustments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_member_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  requested_by     uuid REFERENCES profiles(id) ON DELETE SET NULL,
  delta            numeric(12,2) NOT NULL CHECK (delta <> 0),
  reason           text NOT NULL,
  status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'approved', 'cancelled')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  applied_at       timestamptz
);
CREATE INDEX IF NOT EXISTS savings_adjustments_status_idx
  ON savings_adjustments (status, created_at DESC);
CREATE INDEX IF NOT EXISTS savings_adjustments_target_idx
  ON savings_adjustments (target_member_id) WHERE status = 'approved';

CREATE TABLE IF NOT EXISTS savings_adjustment_approvals (
  adjustment_id uuid NOT NULL REFERENCES savings_adjustments(id) ON DELETE CASCADE,
  admin_id      uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (adjustment_id, admin_id)
);

ALTER TABLE savings_adjustments         ENABLE ROW LEVEL SECURITY;
ALTER TABLE savings_adjustment_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read savings adjustments" ON savings_adjustments;
CREATE POLICY "Admins read savings adjustments" ON savings_adjustments
  FOR SELECT USING (is_admin());

DROP POLICY IF EXISTS "Members read own approved savings adjustments" ON savings_adjustments;
CREATE POLICY "Members read own approved savings adjustments" ON savings_adjustments
  FOR SELECT USING (target_member_id = auth.uid() AND status = 'approved');

DROP POLICY IF EXISTS "Admins read savings approvals" ON savings_adjustment_approvals;
CREATE POLICY "Admins read savings approvals" ON savings_adjustment_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON savings_adjustments, savings_adjustment_approvals TO authenticated;

-- --------------------------------------------------------------------------
-- 2. v_group_pool — include applied savings adjustments
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_group_pool AS
SELECT
    (SELECT COALESCE(SUM(amount_claimed), 0)
       FROM payment_submissions
       WHERE submission_type = 'savings_deposit' AND status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM savings_adjustments WHERE status = 'approved')
  + (SELECT COALESCE(SUM(amount), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM monthly_fees      WHERE status = 'paid')
  + (SELECT COALESCE(SUM(total_due), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM loan_installments WHERE status = 'paid')
  - (SELECT COALESCE(SUM(principal), 0)
       FROM loans             WHERE status IN ('active', 'closed'))
  AS pool_balance_tzs;

-- --------------------------------------------------------------------------
-- 3. Internal: apply the adjustment (called once the threshold is reached).
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION execute_savings_edit(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request savings_adjustments%ROWTYPE;
BEGIN
  SELECT * INTO v_request FROM savings_adjustments WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Edit request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';     END IF;

  UPDATE savings_adjustments
     SET status = 'approved', applied_at = now()
   WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'execute_savings_edit', 'profile', v_request.target_member_id,
          jsonb_build_object(
            'request_id', p_request_id,
            'delta',      v_request.delta,
            'reason',     v_request.reason
          ));

  -- Tell the target their savings changed.
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_request.target_member_id, 'savings_edited',
          'Your savings was adjusted',
          'An admin adjustment of ' || v_request.delta || ' TZS was applied. Reason: ' ||
            v_request.reason,
          jsonb_build_object('request_id', p_request_id, 'delta', v_request.delta));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 4. Public: open a savings-edit request.
--    * Caller must be admin.
--    * Target may be a non-admin member or the caller themselves; NEVER
--      another admin.
--    * Requester does NOT auto-record an approval ("other admins must
--      approve"). With only one admin in the system the request auto-executes
--      (the feature stays usable during single-admin transitions); with 2+
--      admins it goes into the queue at 0/required.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION request_savings_edit(
  p_target_member_id uuid,
  p_delta            numeric,
  p_reason           text
)
RETURNS uuid AS $$
DECLARE
  v_request_id    uuid;
  v_target_role   text;
  v_target_name   text;
  v_requester     text;
  v_other_admins  int;
  v_required      int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_delta = 0   THEN RAISE EXCEPTION 'Delta must be non-zero'; END IF;
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every savings edit';
  END IF;

  SELECT role, full_name INTO v_target_role, v_target_name
    FROM profiles WHERE id = p_target_member_id;
  IF v_target_role IS NULL THEN RAISE EXCEPTION 'Member not found'; END IF;

  -- Admins may only target non-admins or themselves; never another admin.
  IF v_target_role = 'admin' AND p_target_member_id <> auth.uid() THEN
    RAISE EXCEPTION 'Admins cannot edit another admin''s savings';
  END IF;

  -- Block overlapping pending requests for the same target.
  IF EXISTS (
    SELECT 1 FROM savings_adjustments
     WHERE target_member_id = p_target_member_id AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A pending savings edit already exists for this member';
  END IF;

  INSERT INTO savings_adjustments (target_member_id, requested_by, delta, reason)
  VALUES (p_target_member_id, auth.uid(), p_delta, trim(p_reason))
  RETURNING id INTO v_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_savings_edit', 'profile', p_target_member_id,
          jsonb_build_object(
            'request_id',  v_request_id,
            'delta',       p_delta,
            'reason',      p_reason,
            'target_name', v_target_name
          ));

  -- Notify every other admin so they can act.
  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'savings_edit_requested',
         'Savings edit requested',
         COALESCE(v_requester, 'An admin') || ' wants to adjust ' ||
           COALESCE(v_target_name, 'a member') || '''s savings by ' ||
           p_delta || ' TZS',
         jsonb_build_object(
           'request_id', v_request_id,
           'target_id',  p_target_member_id,
           'delta',      p_delta
         )
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  -- Required = min(2, other active admin count). With a single admin in the
  -- system there are no "others" so the request auto-applies.
  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  v_required := least(2, v_other_admins);

  IF v_required = 0 THEN
    PERFORM execute_savings_edit(v_request_id);
  END IF;

  RETURN v_request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. Public: another admin approves. Reaches the threshold → execute.
--    Requester cannot approve their own request; target cannot approve.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_savings_edit(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request      savings_adjustments%ROWTYPE;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM savings_adjustments WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Edit request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed'; END IF;

  -- "Other admins must approve" — neither the requester nor the target may vote.
  IF v_request.requested_by = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;
  IF v_request.target_member_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve an edit to your own savings';
  END IF;

  BEGIN
    INSERT INTO savings_adjustment_approvals (adjustment_id, admin_id)
    VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this edit';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_request.requested_by;
  v_required := least(2, v_other_admins);

  SELECT count(*) INTO v_approvals FROM savings_adjustment_approvals WHERE adjustment_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_savings_edit', 'profile',
            v_request.target_member_id,
            jsonb_build_object(
              'request_id', p_request_id,
              'approvals',  v_approvals,
              'required',   v_required
            ));
    RETURN;
  END IF;

  PERFORM execute_savings_edit(p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 6. Public: any admin can cancel a still-pending savings edit.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cancel_savings_edit(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request savings_adjustments%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM savings_adjustments WHERE id = p_request_id;
  IF v_request.id IS NULL OR v_request.status <> 'pending' THEN
    RETURN;
  END IF;

  UPDATE savings_adjustments SET status = 'cancelled' WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_savings_edit', 'profile', v_request.target_member_id,
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 014_fee_overdue_and_savings.sql
-- ---------------------------------------------------------------------------

-- 014_fee_overdue_and_savings.sql — overdue starts on the 1st of the next month.
--
-- Previously v_fee_status set due_date = period + 1 month (e.g. period 2026-05-01
-- → due_date 2026-06-01) and marked the fee 'overdue' only once today_eat() was
-- STRICTLY AFTER that day, so a May fee became overdue on 2026-06-02. The
-- intended semantic is that an unpaid fee turns overdue on the FIRST day of the
-- next month (2026-06-01 in the example).
--
-- Fix by anchoring due_date to the last day of the period's own month
-- (period + 1 month − 1 day = 2026-05-31), so "today > due_date" yields overdue
-- starting on 2026-06-01. The penalty multiplier likewise increments cleanly:
--   * 2026-06-01: age = 1 day  → penalty_months = 1
--   * 2026-07-01: age = 1 mo   → penalty_months = 2
--   * 2026-08-01: age = 2 mo   → penalty_months = 3
--
-- Column structure of the view is unchanged so CREATE OR REPLACE is safe and
-- v_fee_status_money (which depends on this view) keeps working as-is.
--
-- The "monthly fee paid → counts toward member's savings" change is a
-- frontend-only adjustment (lib/savings.js + the dashboard helpers); the SQL
-- views v_group_pool / v_group_assets already account for paid fees in the
-- group totals, so no SQL change is required for that part.

CREATE OR REPLACE VIEW v_fee_status AS
WITH b AS (
  SELECT mf.*,
         (mf.period + INTERVAL '1 month' - INTERVAL '1 day')::date AS due_date
  FROM monthly_fees mf
)
SELECT
  b.*,
  CASE
    WHEN b.status = 'paid' OR today_eat() <= b.due_date THEN 0
    ELSE (date_part('year',  age(today_eat(), b.due_date)) * 12
        + date_part('month', age(today_eat(), b.due_date)))::int + 1
  END AS penalty_months,
  CASE
    WHEN b.status = 'paid'        THEN 'paid'
    WHEN today_eat() > b.due_date THEN 'overdue'
    ELSE 'pending'
  END AS computed_status
FROM b;

-- ---------------------------------------------------------------------------
-- 015_pool_edits.sql
-- ---------------------------------------------------------------------------

-- 015_pool_edits.sql — 2-of-N pool/total-assets adjustments.
--
-- Total group assets = liquid pool + outstanding loans. Outstanding loans is
-- derived from active loans (not directly editable), so editing total assets
-- means adjusting the pool by a positive or negative delta. This migration
-- introduces a pool_adjustments table mirroring savings_adjustments:
--   * Any admin can open a request.
--   * The requester's vote does NOT auto-count.
--   * Two OTHER admins must approve before the delta applies.
--   * v_group_pool sums approved pool_adjustments alongside other money flows,
--     so the totals card on every dashboard reflects the change immediately.
--
-- Notifications go to every other active admin so they can vote; the audit log
-- captures who requested, who approved, and the reason.

CREATE TABLE IF NOT EXISTS pool_adjustments (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requested_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
  delta        numeric(14,2) NOT NULL CHECK (delta <> 0),
  reason       text NOT NULL,
  status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'cancelled')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  applied_at   timestamptz
);
CREATE INDEX IF NOT EXISTS pool_adjustments_status_idx
  ON pool_adjustments (status, created_at DESC);

CREATE TABLE IF NOT EXISTS pool_adjustment_approvals (
  adjustment_id uuid NOT NULL REFERENCES pool_adjustments(id) ON DELETE CASCADE,
  admin_id      uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (adjustment_id, admin_id)
);

ALTER TABLE pool_adjustments          ENABLE ROW LEVEL SECURITY;
ALTER TABLE pool_adjustment_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read pool adjustments" ON pool_adjustments;
CREATE POLICY "Admins read pool adjustments" ON pool_adjustments
  FOR SELECT USING (is_admin());

DROP POLICY IF EXISTS "Admins read pool approvals" ON pool_adjustment_approvals;
CREATE POLICY "Admins read pool approvals" ON pool_adjustment_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON pool_adjustments, pool_adjustment_approvals TO authenticated;

-- --------------------------------------------------------------------------
-- v_group_pool — include approved pool_adjustments deltas. Column structure
-- unchanged so CREATE OR REPLACE is safe; v_group_assets keeps working.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_group_pool AS
SELECT
    (SELECT COALESCE(SUM(amount_claimed), 0)
       FROM payment_submissions
       WHERE submission_type = 'savings_deposit' AND status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM savings_adjustments WHERE status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM pool_adjustments    WHERE status = 'approved')
  + (SELECT COALESCE(SUM(amount), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM monthly_fees      WHERE status = 'paid')
  + (SELECT COALESCE(SUM(total_due), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM loan_installments WHERE status = 'paid')
  - (SELECT COALESCE(SUM(principal), 0)
       FROM loans             WHERE status IN ('active', 'closed'))
  AS pool_balance_tzs;

-- --------------------------------------------------------------------------
-- Internal: apply the adjustment once the threshold is reached.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION execute_pool_edit(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request pool_adjustments%ROWTYPE;
BEGIN
  SELECT * INTO v_request FROM pool_adjustments WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Pool edit request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';           END IF;

  UPDATE pool_adjustments
     SET status = 'approved', applied_at = now()
   WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'execute_pool_edit', 'pool', NULL,
          jsonb_build_object(
            'request_id', p_request_id,
            'delta',      v_request.delta,
            'reason',     v_request.reason
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- Public: open a pool edit request.
--   * Caller must be admin.
--   * Requester does NOT auto-record a vote — two OTHER admins must approve.
--   * With a single admin in the system the request auto-applies so the
--     feature stays usable during single-admin transitions.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION request_pool_edit(p_delta numeric, p_reason text)
RETURNS uuid AS $$
DECLARE
  v_request_id   uuid;
  v_requester    text;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_delta = 0   THEN RAISE EXCEPTION 'Delta must be non-zero'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every pool edit';
  END IF;

  -- Block overlapping pending requests so the pool doesn't get adjusted twice
  -- on the same conceptual change. Cancelling a pending request unblocks the
  -- next one.
  IF EXISTS (SELECT 1 FROM pool_adjustments WHERE status = 'pending') THEN
    RAISE EXCEPTION 'A pending pool edit already exists; cancel or approve it first';
  END IF;

  INSERT INTO pool_adjustments (requested_by, delta, reason)
  VALUES (auth.uid(), p_delta, trim(p_reason))
  RETURNING id INTO v_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_pool_edit', 'pool', NULL,
          jsonb_build_object(
            'request_id', v_request_id,
            'delta',      p_delta,
            'reason',     p_reason
          ));

  -- Notify every other active admin so they can act.
  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'pool_edit_requested',
         'Pool edit requested',
         COALESCE(v_requester, 'An admin') || ' wants to adjust the group pool by ' ||
           p_delta || ' TZS',
         jsonb_build_object(
           'request_id', v_request_id,
           'delta',      p_delta
         )
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  v_required := least(2, v_other_admins);

  IF v_required = 0 THEN
    PERFORM execute_pool_edit(v_request_id);
  END IF;

  RETURN v_request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- Public: another admin approves. Reaches the threshold → execute.
--   Requester cannot approve their own request.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_pool_edit(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request      pool_adjustments%ROWTYPE;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM pool_adjustments WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Pool edit request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed';   END IF;

  IF v_request.requested_by = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;

  BEGIN
    INSERT INTO pool_adjustment_approvals (adjustment_id, admin_id)
    VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this edit';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_request.requested_by;
  v_required := least(2, v_other_admins);

  SELECT count(*) INTO v_approvals FROM pool_adjustment_approvals WHERE adjustment_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_pool_edit', 'pool', NULL,
            jsonb_build_object(
              'request_id', p_request_id,
              'approvals',  v_approvals,
              'required',   v_required
            ));
    RETURN;
  END IF;

  PERFORM execute_pool_edit(p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- Public: any admin can cancel a pending pool edit.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cancel_pool_edit(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request pool_adjustments%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM pool_adjustments WHERE id = p_request_id;
  IF v_request.id IS NULL OR v_request.status <> 'pending' THEN RETURN; END IF;

  UPDATE pool_adjustments SET status = 'cancelled' WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_pool_edit', 'pool', NULL,
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 016_role_changes.sql
-- ---------------------------------------------------------------------------

-- 016_role_changes.sql — 2-of-N admin role changes.
--
-- An admin can open a request to promote a member to admin or revoke another
-- admin's role. Same governance pattern as savings/pool edits:
--   * The requester's vote does NOT auto-count toward the threshold.
--   * Two OTHER admins must approve before the role flips.
--   * The last remaining admin can never be demoted (mirrors the deletion guard).
--   * 'pending' role-change requests are exclusive per target — cancel an
--     in-flight one to open a new direction.
--
-- Notifications go to every other active admin so they can vote; the audit log
-- captures who requested, who approved, and the reason. The target also gets
-- a notification once the change applies.

CREATE TABLE IF NOT EXISTS role_change_requests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_member_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  requested_by     uuid REFERENCES profiles(id) ON DELETE SET NULL,
  change_type      text NOT NULL CHECK (change_type IN ('promote', 'demote')),
  reason           text NOT NULL,
  status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'approved', 'cancelled')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  applied_at       timestamptz
);
CREATE INDEX IF NOT EXISTS role_change_requests_status_idx
  ON role_change_requests (status, created_at DESC);

CREATE TABLE IF NOT EXISTS role_change_approvals (
  request_id  uuid NOT NULL REFERENCES role_change_requests(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, admin_id)
);

ALTER TABLE role_change_requests  ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_change_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read role-change requests" ON role_change_requests;
CREATE POLICY "Admins read role-change requests" ON role_change_requests
  FOR SELECT USING (is_admin());

DROP POLICY IF EXISTS "Admins read role-change approvals" ON role_change_approvals;
CREATE POLICY "Admins read role-change approvals" ON role_change_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON role_change_requests, role_change_approvals TO authenticated;

-- --------------------------------------------------------------------------
-- Internal: actually flip the role once the threshold is reached.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION execute_role_change(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request               role_change_requests%ROWTYPE;
  v_target_role           text;
  v_remaining_admin_count int;
  v_new_role              text;
BEGIN
  SELECT * INTO v_request FROM role_change_requests WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Role-change request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';             END IF;

  SELECT role INTO v_target_role FROM profiles WHERE id = v_request.target_member_id;
  IF v_target_role IS NULL THEN RAISE EXCEPTION 'Target member not found'; END IF;

  IF v_request.change_type = 'promote' THEN
    IF v_target_role = 'admin' THEN RAISE EXCEPTION 'Member is already an admin'; END IF;
    v_new_role := 'admin';
  ELSE  -- demote
    IF v_target_role <> 'admin' THEN RAISE EXCEPTION 'Member is not an admin'; END IF;
    -- Re-check the last-admin guard at execution time.
    SELECT count(*) INTO v_remaining_admin_count
      FROM profiles WHERE role = 'admin' AND is_active = true
        AND id <> v_request.target_member_id;
    IF v_remaining_admin_count < 1 THEN
      RAISE EXCEPTION 'Cannot revoke the last remaining admin';
    END IF;
    v_new_role := 'member';
  END IF;

  UPDATE profiles SET role = v_new_role WHERE id = v_request.target_member_id;

  UPDATE role_change_requests
     SET status = 'approved', applied_at = now()
   WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'execute_role_change', 'profile', v_request.target_member_id,
          jsonb_build_object(
            'request_id',   p_request_id,
            'change_type',  v_request.change_type,
            'new_role',     v_new_role,
            'reason',       v_request.reason
          ));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_request.target_member_id, 'role_changed',
          CASE WHEN v_request.change_type = 'promote'
               THEN 'You were promoted to admin'
               ELSE 'Your admin role was revoked'
          END,
          v_request.reason,
          jsonb_build_object(
            'request_id',  p_request_id,
            'change_type', v_request.change_type,
            'new_role',    v_new_role
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- Public: open a role-change request.
--   * Caller must be admin.
--   * For 'promote': target must currently be a non-admin member.
--   * For 'demote': target must currently be an admin AND not the last one.
--   * Requester does NOT auto-vote.
--   * No overlapping pending request for the same target.
--   * With 0 other active admins the request auto-applies so the feature
--     stays usable during single-admin transitions.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION request_role_change(
  p_target_member_id uuid,
  p_change_type      text,
  p_reason           text
)
RETURNS uuid AS $$
DECLARE
  v_request_id    uuid;
  v_target_role   text;
  v_target_name   text;
  v_admin_count   int;
  v_other_admins  int;
  v_required      int;
  v_requester     text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_change_type NOT IN ('promote', 'demote') THEN
    RAISE EXCEPTION 'Invalid change_type (use promote or demote)';
  END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every role change';
  END IF;

  SELECT role, full_name INTO v_target_role, v_target_name
    FROM profiles WHERE id = p_target_member_id;
  IF v_target_role IS NULL THEN RAISE EXCEPTION 'Member not found'; END IF;

  IF p_change_type = 'promote' THEN
    IF v_target_role = 'admin' THEN
      RAISE EXCEPTION 'Member is already an admin';
    END IF;
  ELSE  -- demote
    IF v_target_role <> 'admin' THEN
      RAISE EXCEPTION 'Member is not an admin';
    END IF;
    SELECT count(*) INTO v_admin_count
      FROM profiles WHERE role = 'admin' AND is_active = true;
    IF v_admin_count <= 1 THEN
      RAISE EXCEPTION 'Cannot revoke the last remaining admin';
    END IF;
  END IF;

  -- Block overlapping pending requests for the same target.
  IF EXISTS (
    SELECT 1 FROM role_change_requests
     WHERE target_member_id = p_target_member_id AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A pending role-change request already exists for this member';
  END IF;

  INSERT INTO role_change_requests (target_member_id, requested_by, change_type, reason)
  VALUES (p_target_member_id, auth.uid(), p_change_type, trim(p_reason))
  RETURNING id INTO v_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_role_change', 'profile', p_target_member_id,
          jsonb_build_object(
            'request_id',  v_request_id,
            'change_type', p_change_type,
            'reason',      p_reason,
            'target_name', v_target_name
          ));

  -- Notify every OTHER active admin so they can vote.
  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'role_change_requested',
         CASE WHEN p_change_type = 'promote'
              THEN 'Admin promotion requested'
              ELSE 'Admin revocation requested'
         END,
         COALESCE(v_requester, 'An admin') || ' wants to ' || p_change_type || ' ' ||
           COALESCE(v_target_name, 'a member'),
         jsonb_build_object(
           'request_id',  v_request_id,
           'target_id',   p_target_member_id,
           'change_type', p_change_type
         )
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  v_required := least(2, v_other_admins);

  IF v_required = 0 THEN
    PERFORM execute_role_change(v_request_id);
  END IF;

  RETURN v_request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- Public: another admin approves. Requester cannot approve their own request.
-- The target also cannot approve a demotion targeting themselves.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_role_change(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request      role_change_requests%ROWTYPE;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM role_change_requests WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Role-change request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed';     END IF;

  IF v_request.requested_by = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;
  IF v_request.target_member_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve a role change targeting yourself';
  END IF;

  BEGIN
    INSERT INTO role_change_approvals (request_id, admin_id)
    VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this request';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_request.requested_by;
  v_required := least(2, v_other_admins);

  SELECT count(*) INTO v_approvals FROM role_change_approvals WHERE request_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_role_change', 'profile',
            v_request.target_member_id,
            jsonb_build_object(
              'request_id', p_request_id,
              'approvals',  v_approvals,
              'required',   v_required
            ));
    RETURN;
  END IF;

  PERFORM execute_role_change(p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- Public: any admin can cancel a pending role-change request.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cancel_role_change(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request role_change_requests%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM role_change_requests WHERE id = p_request_id;
  IF v_request.id IS NULL OR v_request.status <> 'pending' THEN RETURN; END IF;

  UPDATE role_change_requests SET status = 'cancelled' WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_role_change', 'profile', v_request.target_member_id,
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 017_schedule_monthly_fees.sql
-- ---------------------------------------------------------------------------

-- 017: Schedule monthly fee generation via pg_cron.
--
-- ensure_current_fees() (migration 005) is a SECURITY DEFINER, idempotent upsert that
-- does the same thing as the generate-monthly-fees Edge Function but in pure SQL with
-- no auth.uid() dependency. Scheduling it directly is simpler than deploying the Edge
-- Function + a pg_net HTTP call, and needs no service-role key. Run this once in the
-- Supabase SQL editor.

-- 1. Enable pg_cron (also available via Dashboard → Database → Extensions).
create extension if not exists pg_cron;

-- 2. Schedule for the 1st of each month at 03:00 UTC (= 06:00 EAT, safely inside the
--    1st in East Africa Time). Re-running with the same job name replaces the job.
--    The function uses today_eat() internally, so the exact run time only needs to
--    land on the 1st in EAT.
select cron.schedule(
  'generate-monthly-fees',
  '0 3 1 * *',
  $$ select ensure_current_fees(); $$
);

-- Verify:
--   select jobid, jobname, schedule, command, active from cron.job;
--   select * from cron.job_run_details order by start_time desc limit 5;
--
-- To remove:  select cron.unschedule('generate-monthly-fees');

-- ---------------------------------------------------------------------------
-- 018_self_registration.sql
-- ---------------------------------------------------------------------------

-- 018_self_registration.sql — self-service onboarding (v3).
-- Flips membership from admin-invite-only to self-registration WITH admin approval:
--   * New sign-ups (email/password or Google) land as PENDING (is_active = false)
--     and only become members once an admin approves them.
--   * The profile now carries the richer KYC fields collected at registration.
--   * Members may edit their OWN details via update_own_profile(), which can never
--     touch role/is_active (those stay admin-controlled). No broad self-UPDATE policy
--     is added, so a member still cannot self-activate or self-promote.
-- Apply after 017.

-- ---------------------------------------------------------------------------
-- 1. Richer profile fields. All nullable so Google users (who arrive with only a
--    name + email) can complete them afterwards via /complete-profile.
-- ---------------------------------------------------------------------------
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS email             text,
  ADD COLUMN IF NOT EXISTS secondary_phone   text,
  ADD COLUMN IF NOT EXISTS residence         text,
  ADD COLUMN IF NOT EXISTS national_id       text,
  ADD COLUMN IF NOT EXISTS next_of_kin_name  text,
  ADD COLUMN IF NOT EXISTS next_of_kin_phone text;

-- ---------------------------------------------------------------------------
-- 2. Pending-by-default trigger. Self-registered users start inactive; the
--    admin-create-member Edge Function flips is_active=true for admin-added members.
--    full_name is NOT NULL, so fall back to the email local-part for OAuth users
--    whose provider somehow omits a name. NULLIF('') keeps blank metadata as NULL
--    (so the UNIQUE phone constraint allows many blank pending sign-ups).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (
    id, full_name, phone_number, secondary_phone, email,
    residence, national_id, next_of_kin_name, next_of_kin_phone, is_active
  )
  VALUES (
    NEW.id,
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'full_name', ''), split_part(NEW.email, '@', 1)),
    NULLIF(NEW.raw_user_meta_data->>'phone_number', ''),
    NULLIF(NEW.raw_user_meta_data->>'secondary_phone', ''),
    NEW.email,
    NULLIF(NEW.raw_user_meta_data->>'residence', ''),
    NULLIF(NEW.raw_user_meta_data->>'national_id', ''),
    NULLIF(NEW.raw_user_meta_data->>'next_of_kin_name', ''),
    NULLIF(NEW.raw_user_meta_data->>'next_of_kin_phone', ''),
    false
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 3. update_own_profile — a member edits ONLY their own editable fields. Never
--    touches id / role / is_active / email, so it can't be used to self-activate
--    or self-promote. Used by /complete-profile and the Profile page.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_own_profile(
  p_full_name        text,
  p_phone_number     text,
  p_secondary_phone  text,
  p_residence        text,
  p_national_id      text,
  p_next_of_kin_name text,
  p_next_of_kin_phone text
)
RETURNS void AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF COALESCE(NULLIF(trim(p_full_name), ''), '') = '' THEN
    RAISE EXCEPTION 'Full name is required';
  END IF;
  UPDATE profiles SET
    full_name         = trim(p_full_name),
    phone_number      = NULLIF(trim(p_phone_number), ''),
    secondary_phone   = NULLIF(trim(p_secondary_phone), ''),
    residence         = NULLIF(trim(p_residence), ''),
    national_id       = NULLIF(trim(p_national_id), ''),
    next_of_kin_name  = NULLIF(trim(p_next_of_kin_name), ''),
    next_of_kin_phone = NULLIF(trim(p_next_of_kin_phone), '')
  WHERE id = auth.uid();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 4. approve_member — admin activates a pending sign-up. Single-admin (like
--    admin-create-member) so it works right after a reset when only one admin
--    exists. Audited.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION approve_member(p_member_id uuid)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE profiles SET is_active = true
   WHERE id = p_member_id AND is_active = false;
  IF NOT FOUND THEN RAISE EXCEPTION 'Member not found or already active'; END IF;
  INSERT INTO audit_log (actor_id, action, target_type, target_id)
  VALUES (auth.uid(), 'approve_member', 'profile', p_member_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 5. reject_pending_member — admin declines a pending sign-up, removing the auth
--    user (cascades to the profile). Only valid for inactive, non-admin members;
--    active members must go through the 2-of-N member-deletion flow instead.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reject_pending_member(p_member_id uuid)
RETURNS void AS $$
DECLARE
  v_role   text;
  v_active boolean;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT role, is_active INTO v_role, v_active FROM profiles WHERE id = p_member_id;
  IF NOT FOUND      THEN RAISE EXCEPTION 'Member not found'; END IF;
  IF v_active       THEN RAISE EXCEPTION 'Member is already active; use member deletion instead'; END IF;
  IF v_role = 'admin' THEN RAISE EXCEPTION 'Cannot reject an admin'; END IF;
  INSERT INTO audit_log (actor_id, action, target_type, target_id)
  VALUES (auth.uid(), 'reject_pending_member', 'profile', p_member_id);
  DELETE FROM auth.users WHERE id = p_member_id;  -- cascades to profiles
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION update_own_profile(text, text, text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION approve_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION reject_pending_member(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 019_member_transparency.sql
-- ---------------------------------------------------------------------------

-- 019_member_transparency.sql — group transparency directory (member-facing).
--
-- The group now operates on full mutual transparency: every active member can see
-- every other member's savings balance and outstanding loan. Base-table RLS keeps
-- each member scoped to their own rows (003_rls_policies.sql), so this SECURITY
-- DEFINER function does the per-member aggregation server-side and returns ONLY
-- non-sensitive financial summaries. It deliberately omits phone numbers, NIDA,
-- next-of-kin, emails, and payment-proof screenshots — those stay private.
--
-- Savings mirrors lib/savings.js getApprovedSavings(): approved savings deposits
-- + paid monthly-fee base amounts + admin-approved corrective adjustments.
-- Active loan mirrors v_group_assets: outstanding_principal of the active loan
-- (falling back to principal for loans that pre-date migration 011).

CREATE OR REPLACE FUNCTION group_member_directory()
RETURNS TABLE (
  member_id       uuid,
  full_name       text,
  role            text,
  savings_tzs     numeric,
  active_loan_tzs numeric,
  has_active_loan boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p.id,
    p.full_name,
    p.role,
    COALESCE(dep.total, 0) + COALESCE(fee.total, 0) + COALESCE(adj.total, 0) AS savings_tzs,
    COALESCE(ln.outstanding, 0)                                              AS active_loan_tzs,
    ln.outstanding IS NOT NULL                                              AS has_active_loan
  FROM profiles p
  LEFT JOIN LATERAL (
    SELECT SUM(amount_claimed) AS total
    FROM payment_submissions
    WHERE member_id = p.id
      AND submission_type = 'savings_deposit'
      AND status = 'approved'
  ) dep ON true
  LEFT JOIN LATERAL (
    SELECT SUM(amount) AS total
    FROM monthly_fees
    WHERE member_id = p.id AND status = 'paid'
  ) fee ON true
  LEFT JOIN LATERAL (
    SELECT SUM(delta) AS total
    FROM savings_adjustments
    WHERE target_member_id = p.id AND status = 'approved'
  ) adj ON true
  LEFT JOIN LATERAL (
    SELECT SUM(COALESCE(outstanding_principal, principal)) AS outstanding
    FROM loans
    WHERE member_id = p.id AND status = 'active'
  ) ln ON true
  WHERE p.is_active = true
  ORDER BY p.full_name;
$$;

-- Any signed-in member may call it; anonymous users may not. The function body
-- reveals no PII, so member-level access is the intended transparency.
REVOKE ALL ON FUNCTION group_member_directory() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION group_member_directory() TO authenticated;

-- ---------------------------------------------------------------------------
-- 020_group_settings.sql
-- ---------------------------------------------------------------------------

-- 020_group_settings.sql — the group's financial rules become data, not code.
--
-- Until now the monthly fee (10000), loan interest (5%), penalty rate (5%), pool
-- fraction (25%) and contribution multiplier (3x) were literals scattered across
-- 005/007/011 and lib/loanMath.js. Changing the fee meant shipping a migration.
-- This migration moves them into `group_settings`, readable by every member (the
-- rules are public to the group) and changeable only by 2-of-N admin approval —
-- the same governance the pool/savings/role edits already use (015).
--
-- HISTORY IS NOT REWRITTEN. The `_money` views recompute penalties on every read,
-- so if they read setting('penalty_rate') live, dropping the penalty from 5% to 3%
-- would retroactively restate every unpaid fee ever raised. Instead each
-- money-bearing row SNAPSHOTS the rate that applied when it was created:
--
--     monthly_fees.penalty_rate      loan_installments.penalty_rate
--     loans.interest_rate
--
-- The views use the row's own rate. setting() therefore governs only NEW
-- obligations — an agreed penalty never changes retroactively.
--
-- Existing rows are backfilled with the literal 0.05 they were actually charged at.
--
-- NOTE: approve_submission still hardcodes 0.05 for the interest recalculation; it
-- is rewritten wholesale in 021 (partial payments) and picks up the loan's
-- snapshot rate there. Apply 020 and 021 together.

-- --------------------------------------------------------------------------
-- 1. group_settings
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS group_settings (
  key         text PRIMARY KEY,
  value       numeric(14,4) NOT NULL,
  min_value   numeric(14,4) NOT NULL,
  max_value   numeric(14,4) NOT NULL,
  label       text NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid REFERENCES profiles(id) ON DELETE SET NULL,
  CHECK (value >= min_value AND value <= max_value),
  CHECK (min_value <= max_value)
);

-- Seeded with exactly today's behaviour, so applying this migration changes
-- nothing until an admin votes to change it. min/max are guard rails: they stop a
-- fat-fingered 500% interest rate from ever reaching the table.
INSERT INTO group_settings (key, value, min_value, max_value, label) VALUES
  ('monthly_fee_amount',      10000, 0,    1000000, 'Monthly fee (TZS)'),
  ('loan_interest_rate',       0.05, 0,    0.50,    'Monthly loan interest'),
  ('penalty_rate',             0.05, 0,    0.50,    'Monthly overdue penalty'),
  ('pool_loan_fraction',       0.25, 0.01, 1.00,    'Max share of pool per loan'),
  ('contribution_multiplier',  3,    1,    20,      'Loan cap as multiple of contribution'),
  ('default_loan_months',      3,    1,    12,      'Loan term (months)')
ON CONFLICT (key) DO NOTHING;

ALTER TABLE group_settings ENABLE ROW LEVEL SECURITY;

-- Every member may read the rules they are governed by (consistent with the
-- transparency directory in 019). Writes go through the RPCs below only.
DROP POLICY IF EXISTS "Everyone reads group settings" ON group_settings;
CREATE POLICY "Everyone reads group settings" ON group_settings
  FOR SELECT USING (auth.uid() IS NOT NULL);

GRANT SELECT ON group_settings TO authenticated;

-- --------------------------------------------------------------------------
-- 2. setting() — the accessor every RPC and view default uses.
--
-- STABLE so it can appear in column DEFAULTs and be inlined in queries. The
-- COALESCE fallback means a missing key can never take a live RPC down: the
-- system silently keeps the behaviour it had before this migration.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION setting(p_key text)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT value FROM group_settings WHERE key = p_key),
    CASE p_key
      WHEN 'monthly_fee_amount'     THEN 10000
      WHEN 'loan_interest_rate'     THEN 0.05
      WHEN 'penalty_rate'           THEN 0.05
      WHEN 'pool_loan_fraction'     THEN 0.25
      WHEN 'contribution_multiplier' THEN 3
      WHEN 'default_loan_months'    THEN 3
      ELSE 0
    END
  );
$$;

GRANT EXECUTE ON FUNCTION setting(text) TO authenticated;

-- --------------------------------------------------------------------------
-- 3. Rate snapshots on money-bearing rows.
--
-- Added with a LITERAL 0.05 default first so existing rows are backfilled with
-- the rate they were actually charged at, THEN repointed at setting() so new
-- rows pick up the current rule. Doing it in one step would work today (both
-- evaluate to 0.05) but would silently mis-backfill if this migration were ever
-- replayed after a rate change.
-- --------------------------------------------------------------------------

ALTER TABLE monthly_fees
  ADD COLUMN IF NOT EXISTS penalty_rate numeric(6,4) NOT NULL DEFAULT 0.05;
ALTER TABLE monthly_fees
  ALTER COLUMN penalty_rate SET DEFAULT setting('penalty_rate');

ALTER TABLE loan_installments
  ADD COLUMN IF NOT EXISTS penalty_rate numeric(6,4) NOT NULL DEFAULT 0.05;
ALTER TABLE loan_installments
  ALTER COLUMN penalty_rate SET DEFAULT setting('penalty_rate');

ALTER TABLE loans
  ADD COLUMN IF NOT EXISTS interest_rate numeric(6,4) NOT NULL DEFAULT 0.05;
ALTER TABLE loans
  ALTER COLUMN interest_rate SET DEFAULT setting('loan_interest_rate');

-- The 3-installment schedule was hardcoded as CHECK (installment_number IN (1,2,3)).
-- Now that the term is a setting (1–12 months), the constraint has to widen with it
-- or approve_loan would fail the moment an admin votes for a 4-month term.
ALTER TABLE loan_installments DROP CONSTRAINT IF EXISTS loan_installments_installment_number_check;
ALTER TABLE loan_installments
  ADD CONSTRAINT loan_installments_installment_number_check
  CHECK (installment_number BETWEEN 1 AND 12);

-- --------------------------------------------------------------------------
-- 4. Views — use each row's snapshot rate instead of the literal 0.05.
--
-- All four are DROPped and recreated rather than CREATE OR REPLACEd: the new
-- penalty_rate column lands inside `b.*` / `li.*` and shifts the output column
-- ordering, which CREATE OR REPLACE VIEW forbids (same trap as 011:44-51).
-- The `_money` views are dropped by CASCADE and rebuilt below; grants are
-- dropped with them, so they are re-issued.
-- --------------------------------------------------------------------------

DROP VIEW IF EXISTS v_fee_status_money;
DROP VIEW IF EXISTS v_fee_status CASCADE;

-- Semantics unchanged from 014: a fee is due by the LAST day of its own month, so
-- it turns overdue on the 1st of the next month.
CREATE VIEW v_fee_status AS
WITH b AS (
  SELECT mf.*,
         (mf.period + INTERVAL '1 month' - INTERVAL '1 day')::date AS due_date
  FROM monthly_fees mf
)
SELECT
  b.*,
  CASE
    WHEN b.status = 'paid' OR today_eat() <= b.due_date THEN 0
    ELSE (date_part('year',  age(today_eat(), b.due_date)) * 12
        + date_part('month', age(today_eat(), b.due_date)))::int + 1
  END AS penalty_months,
  CASE
    WHEN b.status = 'paid'        THEN 'paid'
    WHEN today_eat() > b.due_date THEN 'overdue'
    ELSE 'pending'
  END AS computed_status
FROM b;

CREATE VIEW v_fee_status_money AS
SELECT
  f.*,
  round(f.penalty_rate * f.amount * f.penalty_months)            AS penalty_due,
  f.amount + round(f.penalty_rate * f.amount * f.penalty_months) AS total_with_penalty
FROM v_fee_status f;

DROP VIEW IF EXISTS v_installment_status_money;
DROP VIEW IF EXISTS v_installment_status CASCADE;

-- Semantics unchanged from 011: 'cancelled' installments (superseded by early
-- repayment) never accrue a penalty.
CREATE VIEW v_installment_status AS
SELECT
  li.*,
  CASE
    WHEN li.status IN ('paid', 'cancelled') OR today_eat() <= li.due_date THEN 0
    ELSE (date_part('year',  age(today_eat(), li.due_date)) * 12
        + date_part('month', age(today_eat(), li.due_date)))::int + 1
  END AS penalty_months,
  CASE
    WHEN li.status = 'paid'        THEN 'paid'
    WHEN li.status = 'cancelled'   THEN 'cancelled'
    WHEN today_eat() > li.due_date THEN 'overdue'
    ELSE 'pending'
  END AS computed_status
FROM loan_installments li;

CREATE VIEW v_installment_status_money AS
SELECT
  i.*,
  round(i.penalty_rate * i.total_due * i.penalty_months)               AS penalty_due,
  i.total_due + round(i.penalty_rate * i.total_due * i.penalty_months) AS total_with_penalty
FROM v_installment_status i;

GRANT SELECT ON v_fee_status, v_fee_status_money            TO authenticated;
GRANT SELECT ON v_installment_status, v_installment_status_money TO authenticated;

-- --------------------------------------------------------------------------
-- 5. ensure_current_fees — raise the CURRENT fee amount, not a literal 10000.
--    (Replaces the 007 version; keeps its "only audit when rows were created"
--    behaviour so dashboard loads don't flood the log.)
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION ensure_current_fees()
RETURNS void AS $$
DECLARE
  v_period   date := date_trunc('month', today_eat())::date;
  v_amount   numeric(12,2) := setting('monthly_fee_amount');
  v_inserted int;
BEGIN
  WITH inserted AS (
    INSERT INTO monthly_fees (member_id, period, amount, status)
    SELECT p.id, v_period, v_amount, 'pending'
    FROM profiles p
    WHERE p.is_active = true
    ON CONFLICT (member_id, period) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO v_inserted FROM inserted;

  IF v_inserted > 0 THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'generate_monthly_fees', 'system', NULL,
            jsonb_build_object('period', v_period, 'count', v_inserted,
                               'amount', v_amount));
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- --------------------------------------------------------------------------
-- 6. approve_loan — both hard caps and the interest rate come from settings.
--    Otherwise identical to the 011 version (2-of-N, admin-loan restriction,
--    outstanding_principal init). The loan's interest_rate is snapshotted here,
--    at approval, because that is when the schedule is contracted.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_loan(p_loan_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_loan              loans%ROWTYPE;
  v_int               numeric(12,2);
  v_pool              numeric(14,2);
  v_contribution      numeric(14,2);
  v_required          int;
  v_approvals         int;
  v_final_proof       text;
  v_other_admin_loans int;
  v_total_admins      int;
  v_fraction          numeric := setting('pool_loan_fraction');
  v_multiplier        numeric := setting('contribution_multiplier');
  v_rate              numeric := setting('loan_interest_rate');
  v_months            int     := setting('default_loan_months')::int;
  v_n                 int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL             THEN RAISE EXCEPTION 'Loan not found';      END IF;
  IF v_loan.status <> 'pending'    THEN RAISE EXCEPTION 'Loan is not pending'; END IF;
  IF v_loan.member_id = auth.uid() THEN RAISE EXCEPTION 'Cannot approve your own loan'; END IF;

  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;
  IF v_loan.principal > floor(v_fraction * COALESCE(v_pool, 0)) THEN
    RAISE EXCEPTION 'Loan exceeds % of the group pool (max %).',
      round(v_fraction * 100) || '%', floor(v_fraction * COALESCE(v_pool, 0));
  END IF;

  SELECT
      COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                WHERE member_id = v_loan.member_id
                  AND submission_type = 'savings_deposit'
                  AND status = 'approved'), 0)
    + COALESCE((SELECT SUM(amount) FROM monthly_fees
                WHERE member_id = v_loan.member_id AND status = 'paid'), 0)
  INTO v_contribution;
  IF v_loan.principal > floor(v_multiplier * v_contribution) THEN
    RAISE EXCEPTION 'Loan exceeds %x member contribution (max %).',
      v_multiplier, floor(v_multiplier * v_contribution);
  END IF;

  BEGIN
    INSERT INTO loan_approvals (loan_id, admin_id, proof_url)
    VALUES (p_loan_id, auth.uid(), p_proof_url);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this loan';
  END;

  v_required := required_approvals();
  SELECT count(*) INTO v_approvals FROM loan_approvals WHERE loan_id = p_loan_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_loan', 'loan', p_loan_id,
            jsonb_build_object(
              'member_id', v_loan.member_id,
              'principal', v_loan.principal,
              'approvals', v_approvals,
              'required',  v_required
            ));
    RETURN;
  END IF;

  -- Admin-loan restriction: one admin must always remain loan-free.
  IF (SELECT role FROM profiles WHERE id = v_loan.member_id) = 'admin' THEN
    SELECT count(*) INTO v_total_admins
      FROM profiles WHERE role = 'admin' AND is_active = true;
    SELECT count(*) INTO v_other_admin_loans
      FROM loans
      WHERE status = 'active'
        AND member_id IN (SELECT id FROM profiles WHERE role = 'admin' AND is_active = true)
        AND member_id <> v_loan.member_id;
    IF v_other_admin_loans >= v_total_admins - 1 THEN
      RAISE EXCEPTION 'Not all admins may hold loans simultaneously; one admin must remain loan-free.';
    END IF;
  END IF;

  SELECT proof_url INTO v_final_proof
  FROM loan_approvals WHERE loan_id = p_loan_id
  ORDER BY approved_at ASC LIMIT 1;

  v_int := round(v_loan.principal * v_rate);

  UPDATE loans
    SET status = 'active',
        approved_at = now(),
        approved_by = auth.uid(),
        disbursed_at = now(),
        disbursement_proof_url = v_final_proof,
        outstanding_principal = v_loan.principal,
        interest_rate = v_rate
    WHERE id = p_loan_id;

  -- Bullet schedule over `default_loan_months`: interest-only until the final
  -- month, which also clears the principal.
  FOR v_n IN 1..v_months LOOP
    INSERT INTO loan_installments
      (loan_id, installment_number, due_date, principal_due, interest_due, penalty_rate)
    VALUES (
      p_loan_id,
      v_n,
      (today_eat() + (v_n || ' month')::interval)::date,
      CASE WHEN v_n = v_months THEN v_loan.principal ELSE 0 END,
      v_int,
      setting('penalty_rate')
    );
  END LOOP;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_loan', 'loan', p_loan_id,
          jsonb_build_object(
            'member_id',     v_loan.member_id,
            'principal',     v_loan.principal,
            'approvals',     v_approvals,
            'interest_rate', v_rate,
            'months',        v_months
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- --------------------------------------------------------------------------
-- 7. 2-of-N setting changes — same shape as pool edits (015).
--    * Any admin opens a request; their own vote does NOT auto-count.
--    * Two OTHER admins approve before it applies.
--    * With a single admin it auto-applies so the feature stays usable.
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS setting_changes (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key           text NOT NULL REFERENCES group_settings(key) ON DELETE CASCADE,
  old_value     numeric(14,4) NOT NULL,
  new_value     numeric(14,4) NOT NULL,
  reason        text NOT NULL,
  requested_by  uuid REFERENCES profiles(id) ON DELETE SET NULL,
  status        text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'approved', 'cancelled')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  applied_at    timestamptz,
  CHECK (new_value <> old_value)
);
CREATE INDEX IF NOT EXISTS setting_changes_status_idx
  ON setting_changes (status, created_at DESC);

CREATE TABLE IF NOT EXISTS setting_change_approvals (
  change_id   uuid NOT NULL REFERENCES setting_changes(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (change_id, admin_id)
);

ALTER TABLE setting_changes          ENABLE ROW LEVEL SECURITY;
ALTER TABLE setting_change_approvals ENABLE ROW LEVEL SECURITY;

-- Members may watch a proposed rule change (it governs them); only admins vote.
DROP POLICY IF EXISTS "Everyone reads setting changes" ON setting_changes;
CREATE POLICY "Everyone reads setting changes" ON setting_changes
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Admins read setting approvals" ON setting_change_approvals;
CREATE POLICY "Admins read setting approvals" ON setting_change_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON setting_changes, setting_change_approvals TO authenticated;

CREATE OR REPLACE FUNCTION execute_setting_change(p_change_id uuid)
RETURNS void AS $$
DECLARE
  v_change setting_changes%ROWTYPE;
BEGIN
  SELECT * INTO v_change FROM setting_changes WHERE id = p_change_id FOR UPDATE;
  IF v_change.id IS NULL          THEN RAISE EXCEPTION 'Setting change not found'; END IF;
  IF v_change.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';        END IF;

  UPDATE group_settings
     SET value = v_change.new_value, updated_at = now(), updated_by = auth.uid()
   WHERE key = v_change.key;

  UPDATE setting_changes
     SET status = 'approved', applied_at = now()
   WHERE id = p_change_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'execute_setting_change', 'setting', NULL,
          jsonb_build_object(
            'change_id', p_change_id,
            'key',       v_change.key,
            'old_value', v_change.old_value,
            'new_value', v_change.new_value,
            'reason',    v_change.reason
          ));

  -- Everyone is governed by the rules, so everyone is told when they change.
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'setting_changed',
         'Group rule changed',
         (SELECT label FROM group_settings WHERE key = v_change.key) ||
           ' changed from ' || v_change.old_value || ' to ' || v_change.new_value,
         jsonb_build_object('key', v_change.key, 'new_value', v_change.new_value)
    FROM profiles p
   WHERE p.is_active = true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION request_setting_change(
  p_key text, p_new_value numeric, p_reason text
)
RETURNS uuid AS $$
DECLARE
  v_change_id    uuid;
  v_current      group_settings%ROWTYPE;
  v_requester    text;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every rule change';
  END IF;

  SELECT * INTO v_current FROM group_settings WHERE key = p_key;
  IF v_current.key IS NULL THEN RAISE EXCEPTION 'Unknown setting: %', p_key; END IF;

  IF p_new_value = v_current.value THEN
    RAISE EXCEPTION 'That is already the current value';
  END IF;
  IF p_new_value < v_current.min_value OR p_new_value > v_current.max_value THEN
    RAISE EXCEPTION '% must be between % and %',
      v_current.label, v_current.min_value, v_current.max_value;
  END IF;

  -- One pending change per key, so two admins can't approve conflicting values.
  IF EXISTS (SELECT 1 FROM setting_changes WHERE key = p_key AND status = 'pending') THEN
    RAISE EXCEPTION 'A pending change for this setting already exists; cancel or approve it first';
  END IF;

  INSERT INTO setting_changes (key, old_value, new_value, reason, requested_by)
  VALUES (p_key, v_current.value, p_new_value, trim(p_reason), auth.uid())
  RETURNING id INTO v_change_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_setting_change', 'setting', NULL,
          jsonb_build_object(
            'change_id', v_change_id,
            'key',       p_key,
            'old_value', v_current.value,
            'new_value', p_new_value,
            'reason',    p_reason
          ));

  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'setting_change_requested',
         'Rule change proposed',
         COALESCE(v_requester, 'An admin') || ' wants to change ' || v_current.label ||
           ' from ' || v_current.value || ' to ' || p_new_value,
         jsonb_build_object('change_id', v_change_id, 'key', p_key)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  v_required := least(2, v_other_admins);

  IF v_required = 0 THEN
    PERFORM execute_setting_change(v_change_id);
  END IF;

  RETURN v_change_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION approve_setting_change(p_change_id uuid)
RETURNS void AS $$
DECLARE
  v_change       setting_changes%ROWTYPE;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_change FROM setting_changes WHERE id = p_change_id FOR UPDATE;
  IF v_change.id IS NULL          THEN RAISE EXCEPTION 'Setting change not found'; END IF;
  IF v_change.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed'; END IF;
  IF v_change.requested_by = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;

  BEGIN
    INSERT INTO setting_change_approvals (change_id, admin_id)
    VALUES (p_change_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this change';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_change.requested_by;
  v_required := least(2, v_other_admins);

  SELECT count(*) INTO v_approvals FROM setting_change_approvals WHERE change_id = p_change_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_setting_change', 'setting', NULL,
            jsonb_build_object(
              'change_id', p_change_id,
              'approvals', v_approvals,
              'required',  v_required
            ));
    RETURN;
  END IF;

  PERFORM execute_setting_change(p_change_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION cancel_setting_change(p_change_id uuid)
RETURNS void AS $$
DECLARE
  v_change setting_changes%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_change FROM setting_changes WHERE id = p_change_id;
  IF v_change.id IS NULL OR v_change.status <> 'pending' THEN RETURN; END IF;

  UPDATE setting_changes SET status = 'cancelled' WHERE id = p_change_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_setting_change', 'setting', NULL,
          jsonb_build_object('change_id', p_change_id, 'key', v_change.key));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 021_partial_payments.sql
-- ---------------------------------------------------------------------------

-- 021_partial_payments.sql — accept the money members actually have.
--
-- Until now approve_submission refused anything below the full contracted amount:
--
--     IF v_final_amount < v_inst.total_due + v_penalty THEN
--       RAISE EXCEPTION 'Payment of % is below the required minimum %…'
--
-- So a member holding 60% of an installment could pay NOTHING, and a month later
-- was charged another 5% penalty on the whole amount. This migration replaces the
-- all-or-nothing rule with an allocation waterfall and a 'partial' status.
--
-- ALLOCATION WATERFALL (penalty first, principal last — the borrower's cheapest
-- debt is retired last, which is the standard order and stops a member from
-- servicing principal while a penalty compounds):
--
--   monthly fee        penalty → base
--   loan installment   penalty → interest → contracted principal → extra principal
--
-- A row becomes 'paid' only when nothing is left; otherwise 'partial'. Penalties
-- accrue on the REMAINING balance, so a member who has paid 80% is fined on the
-- 20% still owed, not on the original total.
--
-- Overpayment is never silently absorbed: on a loan it reduces principal early
-- (as before), and once there is genuinely nothing left to allocate to, the RPC
-- raises rather than booking the excess as a mystery "penalty". The admin logs the
-- surplus as a savings deposit instead.
--
-- v_group_pool CORRECTION (load-bearing). It summed `amount` / `total_due` for rows
-- WHERE status = 'paid'. With partial payments that would undercount cash on hand.
-- It now sums the actual paid columns across every row. This also fixes a
-- pre-existing bug: extra principal paid early (principal_paid above principal_due)
-- was never credited to the pool, because only total_due was counted.
--
-- Requires 020 (penalty_rate snapshots).

-- --------------------------------------------------------------------------
-- 1. Schema — how much of each obligation has actually been settled.
--    `penalty_collected` already exists on both tables and keeps its meaning
--    (cumulative penalty banked), so no separate penalty_paid column is added.
-- --------------------------------------------------------------------------

ALTER TABLE monthly_fees
  ADD COLUMN IF NOT EXISTS amount_paid numeric(12,2) NOT NULL DEFAULT 0;

ALTER TABLE loan_installments
  ADD COLUMN IF NOT EXISTS interest_paid numeric(12,2) NOT NULL DEFAULT 0;

-- Backfill: every row already marked 'paid' was, by the old all-or-nothing rule,
-- settled in full.
UPDATE monthly_fees      SET amount_paid   = amount       WHERE status = 'paid' AND amount_paid = 0;
UPDATE loan_installments SET interest_paid = interest_due WHERE status = 'paid' AND interest_paid = 0;
-- principal_paid was only populated from 011 onward; older paid rows settled their
-- contracted principal_due in full.
UPDATE loan_installments SET principal_paid = principal_due
 WHERE status = 'paid' AND principal_paid = 0 AND principal_due > 0;

ALTER TABLE monthly_fees DROP CONSTRAINT IF EXISTS monthly_fees_status_check;
ALTER TABLE monthly_fees
  ADD CONSTRAINT monthly_fees_status_check
  CHECK (status IN ('pending', 'partial', 'paid'));

ALTER TABLE loan_installments DROP CONSTRAINT IF EXISTS loan_installments_status_check;
ALTER TABLE loan_installments
  ADD CONSTRAINT loan_installments_status_check
  CHECK (status IN ('pending', 'partial', 'paid', 'cancelled'));

-- --------------------------------------------------------------------------
-- 2. Views — penalties accrue on what is STILL OWED, and every view exposes the
--    remaining balance so the UI can render "paid X of Y".
--
--    DROP + recreate (not CREATE OR REPLACE): the new columns land inside `mf.*` /
--    `li.*` and shift the output ordering, which CREATE OR REPLACE VIEW forbids.
-- --------------------------------------------------------------------------

DROP VIEW IF EXISTS v_fee_status_money;
DROP VIEW IF EXISTS v_fee_status CASCADE;

CREATE VIEW v_fee_status AS
WITH b AS (
  SELECT mf.*,
         (mf.period + INTERVAL '1 month' - INTERVAL '1 day')::date AS due_date,
         greatest(mf.amount - mf.amount_paid, 0)                   AS remaining
  FROM monthly_fees mf
)
SELECT
  b.*,
  CASE
    WHEN b.status = 'paid' OR b.remaining <= 0 OR today_eat() <= b.due_date THEN 0
    ELSE (date_part('year',  age(today_eat(), b.due_date)) * 12
        + date_part('month', age(today_eat(), b.due_date)))::int + 1
  END AS penalty_months,
  -- 'overdue' outranks 'partial': being past due is the signal that matters, and
  -- amount_paid > 0 tells the UI to render it as partly settled.
  CASE
    WHEN b.status = 'paid' OR b.remaining <= 0 THEN 'paid'
    WHEN today_eat() > b.due_date              THEN 'overdue'
    WHEN b.amount_paid > 0                     THEN 'partial'
    ELSE 'pending'
  END AS computed_status
FROM b;

-- total_with_penalty is now "what is still owed", not "the original amount plus a
-- penalty" — for an untouched fee the two are identical, so nothing changes for
-- rows nobody has paid into.
CREATE VIEW v_fee_status_money AS
SELECT
  f.*,
  round(f.penalty_rate * f.remaining * f.penalty_months)              AS penalty_due,
  f.remaining + round(f.penalty_rate * f.remaining * f.penalty_months) AS total_with_penalty
FROM v_fee_status f;

DROP VIEW IF EXISTS v_installment_status_money;
DROP VIEW IF EXISTS v_installment_status CASCADE;

CREATE VIEW v_installment_status AS
WITH b AS (
  SELECT li.*,
         greatest(li.interest_due  - li.interest_paid,  0) AS interest_remaining,
         -- principal_paid can exceed principal_due when a borrower repays early,
         -- so this is clamped at zero rather than going negative.
         greatest(li.principal_due - li.principal_paid, 0) AS principal_remaining
  FROM loan_installments li
)
SELECT
  b.*,
  (b.interest_remaining + b.principal_remaining) AS remaining,
  CASE
    WHEN b.status IN ('paid', 'cancelled')
      OR (b.interest_remaining + b.principal_remaining) <= 0
      OR today_eat() <= b.due_date THEN 0
    ELSE (date_part('year',  age(today_eat(), b.due_date)) * 12
        + date_part('month', age(today_eat(), b.due_date)))::int + 1
  END AS penalty_months,
  CASE
    WHEN b.status = 'cancelled' THEN 'cancelled'
    WHEN b.status = 'paid' OR (b.interest_remaining + b.principal_remaining) <= 0 THEN 'paid'
    WHEN today_eat() > b.due_date THEN 'overdue'
    WHEN (b.interest_paid + b.principal_paid) > 0 THEN 'partial'
    ELSE 'pending'
  END AS computed_status
FROM b;

CREATE VIEW v_installment_status_money AS
SELECT
  i.*,
  round(i.penalty_rate * i.remaining * i.penalty_months)               AS penalty_due,
  i.remaining + round(i.penalty_rate * i.remaining * i.penalty_months) AS total_with_penalty
FROM v_installment_status i;

GRANT SELECT ON v_fee_status, v_fee_status_money                 TO authenticated;
GRANT SELECT ON v_installment_status, v_installment_status_money TO authenticated;

-- --------------------------------------------------------------------------
-- 3. v_group_pool — count cash actually received, not contracted amounts.
--    Column structure is unchanged, so CREATE OR REPLACE is safe and
--    v_group_assets keeps working.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_group_pool AS
SELECT
    (SELECT COALESCE(SUM(amount_claimed), 0)
       FROM payment_submissions
       WHERE submission_type = 'savings_deposit' AND status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM savings_adjustments WHERE status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM pool_adjustments    WHERE status = 'approved')
  -- Every shilling banked against a fee, whether the fee is fully settled or not.
  + (SELECT COALESCE(SUM(amount_paid), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM monthly_fees)
  -- interest_paid + principal_paid captures early principal repayment, which the
  -- old SUM(total_due) silently dropped.
  + (SELECT COALESCE(SUM(interest_paid), 0)
           + COALESCE(SUM(principal_paid), 0)
           + COALESCE(SUM(penalty_collected), 0)
       FROM loan_installments)
  - (SELECT COALESCE(SUM(principal), 0)
       FROM loans             WHERE status IN ('active', 'closed'))
  AS pool_balance_tzs;

-- --------------------------------------------------------------------------
-- 4. group_member_directory — a member's savings must count partially-paid fees
--    too, or the transparency page under-reports everyone who is mid-payment.
--    (Mirrors lib/savings.js getApprovedSavings.)
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION group_member_directory()
RETURNS TABLE (
  member_id       uuid,
  full_name       text,
  role            text,
  savings_tzs     numeric,
  active_loan_tzs numeric,
  has_active_loan boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p.id,
    p.full_name,
    p.role,
    COALESCE(dep.total, 0) + COALESCE(fee.total, 0) + COALESCE(adj.total, 0) AS savings_tzs,
    COALESCE(ln.outstanding, 0)                                              AS active_loan_tzs,
    ln.outstanding IS NOT NULL                                               AS has_active_loan
  FROM profiles p
  LEFT JOIN LATERAL (
    SELECT SUM(amount_claimed) AS total
    FROM payment_submissions
    WHERE member_id = p.id
      AND submission_type = 'savings_deposit'
      AND status = 'approved'
  ) dep ON true
  LEFT JOIN LATERAL (
    SELECT SUM(amount_paid) AS total
    FROM monthly_fees
    WHERE member_id = p.id
  ) fee ON true
  LEFT JOIN LATERAL (
    SELECT SUM(delta) AS total
    FROM savings_adjustments
    WHERE target_member_id = p.id AND status = 'approved'
  ) adj ON true
  LEFT JOIN LATERAL (
    SELECT COALESCE(outstanding_principal, principal) AS outstanding
    FROM loans
    WHERE member_id = p.id AND status = 'active'
    ORDER BY approved_at DESC NULLS LAST
    LIMIT 1
  ) ln ON true
  WHERE p.is_active = true
  ORDER BY p.full_name;
$$;

GRANT EXECUTE ON FUNCTION group_member_directory() TO authenticated;

-- --------------------------------------------------------------------------
-- 5. earnings_ledger — group income, recorded with a DATE as it is collected.
--
--    The pool tells you what the group holds; it cannot tell you what the group
--    EARNED, or when. Interest and penalties are the group's profit — the money a
--    share-out distributes — and they are indistinguishable from returned capital
--    once they land in the pool. Recording each one at the moment of collection is
--    what makes an end-of-cycle share-out possible (migration 024) without
--    reconstructing history from balances that have no timestamps.
--
--    Positive = income, negative = loss (a write-off, migration 022).
--    `submission_id` lets the capital calculation subtract the penalty portion of
--    a fee payment, leaving the part that is genuinely the member's savings.
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS earnings_ledger (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id     uuid REFERENCES profiles(id) ON DELETE SET NULL,
  kind          text NOT NULL CHECK (kind IN ('interest', 'penalty', 'write_off')),
  amount        numeric(14,2) NOT NULL,
  submission_id uuid REFERENCES payment_submissions(id) ON DELETE SET NULL,
  source_type   text,
  source_id     uuid,
  occurred_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS earnings_ledger_occurred_idx ON earnings_ledger (occurred_at);
CREATE INDEX IF NOT EXISTS earnings_ledger_submission_idx ON earnings_ledger (submission_id);

ALTER TABLE earnings_ledger ENABLE ROW LEVEL SECURITY;

-- Group income is group business: every member can see what the group earned.
-- (Consistent with the transparency directory in 019.)
DROP POLICY IF EXISTS "Everyone reads earnings" ON earnings_ledger;
CREATE POLICY "Everyone reads earnings" ON earnings_ledger
  FOR SELECT USING (auth.uid() IS NOT NULL);

GRANT SELECT ON earnings_ledger TO authenticated;

-- --------------------------------------------------------------------------
-- 6. approve_submission — the allocation waterfall.
--
--    2-of-N is unchanged: the FIRST approver's amount_received is the one that
--    gets allocated when the threshold is reached.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_submission(p_submission_id uuid, p_amount_received numeric)
RETURNS void AS $$
DECLARE
  s                 payment_submissions%ROWTYPE;
  v_required        int;
  v_approvals       int;
  v_final_amount    numeric(12,2);
  v_left            numeric(12,2);
  v_penalty         numeric(12,2);
  v_pay             numeric(12,2);
  -- fee
  v_fee             monthly_fees%ROWTYPE;
  v_fee_remaining   numeric(12,2);
  -- installment
  v_inst            loan_installments%ROWTYPE;
  v_loan_id         uuid;
  v_int_remaining   numeric(12,2);
  v_prin_remaining  numeric(12,2);
  v_interest_pay    numeric(12,2);
  v_principal_pay   numeric(12,2);
  v_extra_principal numeric(12,2);
  v_outstanding     numeric(12,2);
  v_rate            numeric;
  v_new_int         numeric(12,2);
  v_last            int;
  v_interest_open   int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_amount_received IS NULL OR p_amount_received <= 0 THEN
    RAISE EXCEPTION 'Invalid amount received';
  END IF;

  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id FOR UPDATE;
  IF s.id IS NULL             THEN RAISE EXCEPTION 'Submission not found'; END IF;
  IF s.status <> 'pending'    THEN RAISE EXCEPTION 'Already reviewed';    END IF;
  IF s.member_id = auth.uid() THEN RAISE EXCEPTION 'Cannot approve your own submission'; END IF;

  BEGIN
    INSERT INTO submission_approvals (submission_id, admin_id, amount_received)
    VALUES (p_submission_id, auth.uid(), p_amount_received);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this submission';
  END;

  v_required := required_approvals();
  SELECT count(*) INTO v_approvals FROM submission_approvals WHERE submission_id = p_submission_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_submission', 'submission', p_submission_id,
            jsonb_build_object(
              'submission_type', s.submission_type,
              'member_id',       s.member_id,
              'amount_received', p_amount_received,
              'approvals',       v_approvals,
              'required',        v_required
            ));
    RETURN;
  END IF;

  SELECT amount_received INTO v_final_amount
  FROM submission_approvals
  WHERE submission_id = p_submission_id
  ORDER BY approved_at ASC
  LIMIT 1;

  UPDATE payment_submissions
    SET status = 'approved', reviewed_at = now(), reviewed_by = auth.uid()
    WHERE id = p_submission_id;

  v_left := v_final_amount;

  -- ---------------------------------------------------------------- monthly fee
  IF s.submission_type = 'monthly_fee' THEN
    SELECT * INTO v_fee FROM monthly_fees WHERE id = s.related_id FOR UPDATE;
    IF v_fee.id IS NULL THEN RAISE EXCEPTION 'Monthly fee not found'; END IF;

    SELECT COALESCE(penalty_due, 0) INTO v_penalty
      FROM v_fee_status_money WHERE id = v_fee.id;
    v_fee_remaining := greatest(v_fee.amount - v_fee.amount_paid, 0);

    IF v_left > v_penalty + v_fee_remaining THEN
      RAISE EXCEPTION
        'Payment of % exceeds the % still owed on this fee (% base + % penalty). Approve the exact amount and log any surplus as a savings deposit.',
        v_left, v_penalty + v_fee_remaining, v_fee_remaining, v_penalty;
    END IF;

    v_pay  := least(v_left, v_penalty);          -- penalty first
    v_left := v_left - v_pay;
    UPDATE monthly_fees
       SET penalty_collected = penalty_collected + v_pay,
           amount_paid       = amount_paid + least(v_left, v_fee_remaining),
           reviewed_by       = auth.uid()
     WHERE id = v_fee.id;

    UPDATE monthly_fees
       SET status  = CASE WHEN amount_paid >= amount THEN 'paid' ELSE 'partial' END,
           paid_at = CASE WHEN amount_paid >= amount THEN now() ELSE paid_at END
     WHERE id = v_fee.id;

    -- The penalty is group income; the base is the member's own capital.
    IF v_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'penalty', v_pay, p_submission_id, 'monthly_fee', v_fee.id);
    END IF;

  -- ----------------------------------------------------------- loan installment
  ELSIF s.submission_type = 'loan_installment' THEN
    SELECT * INTO v_inst FROM loan_installments WHERE id = s.related_id FOR UPDATE;
    IF v_inst.id IS NULL THEN RAISE EXCEPTION 'Installment not found'; END IF;
    v_loan_id := v_inst.loan_id;

    SELECT COALESCE(penalty_due, 0) INTO v_penalty
      FROM v_installment_status_money WHERE id = v_inst.id;

    v_int_remaining  := greatest(v_inst.interest_due  - v_inst.interest_paid,  0);
    v_prin_remaining := greatest(v_inst.principal_due - v_inst.principal_paid, 0);

    SELECT outstanding_principal, interest_rate INTO v_outstanding, v_rate
      FROM loans WHERE id = v_loan_id FOR UPDATE;

    -- Ceiling on what this payment can possibly settle: the penalty, the interest
    -- still owed on this installment, and every shilling of principal still out.
    IF v_left > v_penalty + v_int_remaining + v_outstanding THEN
      RAISE EXCEPTION
        'Payment of % exceeds everything outstanding on this loan (%). Approve the exact amount and log any surplus as a savings deposit.',
        v_left, v_penalty + v_int_remaining + v_outstanding;
    END IF;

    v_pay  := least(v_left, v_penalty);               -- 1. penalty
    v_left := v_left - v_pay;

    v_interest_pay := least(v_left, v_int_remaining); -- 2. interest
    v_left := v_left - v_interest_pay;

    v_principal_pay := least(v_left, v_prin_remaining); -- 3. contracted principal
    v_left := v_left - v_principal_pay;

    -- 4. anything still left retires principal early
    v_extra_principal := least(v_left, greatest(v_outstanding - v_principal_pay, 0));

    UPDATE loan_installments
       SET penalty_collected = penalty_collected + v_pay,
           interest_paid     = interest_paid + v_interest_pay,
           principal_paid    = principal_paid + v_principal_pay + v_extra_principal,
           reviewed_by       = auth.uid()
     WHERE id = v_inst.id;

    UPDATE loan_installments
       SET status  = CASE
                       WHEN interest_paid >= interest_due AND principal_paid >= principal_due
                       THEN 'paid' ELSE 'partial'
                     END,
           paid_at = CASE
                       WHEN interest_paid >= interest_due AND principal_paid >= principal_due
                       THEN now() ELSE paid_at
                     END
     WHERE id = v_inst.id;

    v_outstanding := v_outstanding - v_principal_pay - v_extra_principal;
    UPDATE loans SET outstanding_principal = v_outstanding WHERE id = v_loan_id;

    -- Interest and penalty are the group's earnings on this loan; principal is the
    -- group's own money coming back and is NOT income.
    IF v_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'penalty', v_pay, p_submission_id, 'loan_installment', v_inst.id);
    END IF;
    IF v_interest_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'interest', v_interest_pay, p_submission_id, 'loan_installment', v_inst.id);
    END IF;

    -- Is any interest still owed anywhere on this loan? The waterfall pays interest
    -- before principal, so this is normally 0 by the time principal clears — the
    -- check is here so an underpaid loan can never close with interest outstanding.
    SELECT count(*) INTO v_interest_open
      FROM loan_installments
     WHERE loan_id = v_loan_id
       AND status <> 'cancelled'
       AND interest_paid < interest_due;

    IF v_outstanding <= 0 AND v_interest_open = 0 THEN
      UPDATE loans SET status = 'closed' WHERE id = v_loan_id;
      UPDATE loan_installments
         SET status = 'cancelled'
       WHERE loan_id = v_loan_id AND status = 'pending';
    ELSE
      -- Re-price the UNTOUCHED installments against the new outstanding balance.
      -- 'partial' rows are deliberately excluded: restating the interest on a row
      -- someone has already part-paid would rewrite an agreed figure.
      v_new_int := round(v_outstanding * COALESCE(v_rate, 0.05));
      SELECT max(installment_number) INTO v_last
        FROM loan_installments WHERE loan_id = v_loan_id AND status <> 'cancelled';

      UPDATE loan_installments
         SET interest_due  = v_new_int,
             principal_due = CASE WHEN installment_number = v_last THEN v_outstanding ELSE 0 END
       WHERE loan_id = v_loan_id
         AND status = 'pending';
    END IF;

  -- --------------------------------------------------------------------- savings
  ELSE
    UPDATE payment_submissions SET amount_claimed = v_final_amount
      WHERE id = p_submission_id;
  END IF;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_submission', 'submission', p_submission_id,
          jsonb_build_object(
            'submission_type', s.submission_type,
            'member_id',       s.member_id,
            'amount_received', v_final_amount,
            'approvals',       v_approvals
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ---------------------------------------------------------------------------
-- 022_loan_distress.sql
-- ---------------------------------------------------------------------------

-- 022_loan_distress.sql — what happens when a loan goes bad.
--
-- Before this migration `loans.status` was (pending, active, closed, rejected). A
-- borrower who could not repay simply accrued 5% a month forever: there was no way
-- to reschedule, to write the debt off, or to settle it against the savings they
-- already hold in the pool. Three admin actions, each 2-of-N, fill that gap:
--
--   restructure  — cancel the untouched installments and re-cut the schedule over a
--                  new term against the CURRENT outstanding principal.
--   write off    — recognise the loss: outstanding → 0, loan closed as written_off,
--                  the pool permanently absorbs the principal.
--   recover from — settle part or all of the debt against the borrower's own
--   savings       savings, which are already sitting in the pool.
--
-- NOT ADDED: a manual 'defaulted' status. A status an admin has to remember to set
-- drifts out of sync with reality the moment someone forgets. `v_loan_risk` below
-- derives non-performance from the installment record instead, so it is always
-- current and needs no maintenance.
--
-- RESTRUCTURING FORGIVES ACCRUED PENALTY on the installments it cancels — cancelled
-- rows stop accruing (021's views return penalty_months = 0 for them). That is a
-- real decision, which is why it takes two admin signatures and lands in audit_log.
--
-- Requires 020 (interest_rate snapshot) and 021 (partial payments).

-- --------------------------------------------------------------------------
-- 1. Schema
-- --------------------------------------------------------------------------

ALTER TABLE loans DROP CONSTRAINT IF EXISTS loans_status_check;
ALTER TABLE loans
  ADD CONSTRAINT loans_status_check
  CHECK (status IN ('pending', 'active', 'closed', 'rejected', 'written_off'));

-- A restructure appends installments after the existing ones, so a loan that is
-- rescheduled more than once can pass 12. The UNIQUE (loan_id, installment_number)
-- constraint is what actually keeps them distinct.
ALTER TABLE loan_installments DROP CONSTRAINT IF EXISTS loan_installments_installment_number_check;
ALTER TABLE loan_installments
  ADD CONSTRAINT loan_installments_installment_number_check
  CHECK (installment_number > 0);

-- One table for all three actions, mirroring pool_adjustments (015).
CREATE TABLE IF NOT EXISTS loan_actions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_id      uuid NOT NULL REFERENCES loans(id) ON DELETE CASCADE,
  action       text NOT NULL CHECK (action IN ('restructure', 'write_off', 'recover_from_savings')),
  amount       numeric(12,2),   -- recover_from_savings only
  term_months  int,             -- restructure only
  reason       text NOT NULL,
  requested_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
  status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'cancelled')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  applied_at   timestamptz
);
CREATE INDEX IF NOT EXISTS loan_actions_status_idx ON loan_actions (status, created_at DESC);

CREATE TABLE IF NOT EXISTS loan_action_approvals (
  action_id   uuid NOT NULL REFERENCES loan_actions(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (action_id, admin_id)
);

-- Recoveries are booked against the pool to cancel out the negative savings
-- adjustment they create. No cash moves when a debt is settled from savings: the
-- member's claim on the pool shrinks and the receivable shrinks with it, so the
-- pool's CASH balance must stay exactly where it was. Without this offset the
-- savings adjustment alone would double-count the loss.
CREATE TABLE IF NOT EXISTS loan_recoveries (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_id     uuid NOT NULL REFERENCES loans(id) ON DELETE CASCADE,
  member_id   uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  amount      numeric(12,2) NOT NULL CHECK (amount > 0),
  action_id   uuid REFERENCES loan_actions(id) ON DELETE SET NULL,
  recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS loan_recoveries_loan_idx ON loan_recoveries (loan_id);

ALTER TABLE loan_actions          ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_action_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_recoveries       ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read loan actions" ON loan_actions;
CREATE POLICY "Admins read loan actions" ON loan_actions
  FOR SELECT USING (is_admin());

-- A borrower can see what is being proposed about their own loan.
DROP POLICY IF EXISTS "Borrower reads own loan actions" ON loan_actions;
CREATE POLICY "Borrower reads own loan actions" ON loan_actions
  FOR SELECT USING (loan_id IN (SELECT id FROM loans WHERE member_id = auth.uid()));

DROP POLICY IF EXISTS "Admins read loan action approvals" ON loan_action_approvals;
CREATE POLICY "Admins read loan action approvals" ON loan_action_approvals
  FOR SELECT USING (is_admin());

DROP POLICY IF EXISTS "Read own or all recoveries" ON loan_recoveries;
CREATE POLICY "Read own or all recoveries" ON loan_recoveries
  FOR SELECT USING (member_id = auth.uid() OR is_admin());

GRANT SELECT ON loan_actions, loan_action_approvals, loan_recoveries TO authenticated;

-- --------------------------------------------------------------------------
-- 2. v_group_pool — recognise written-off principal and recovery offsets.
--
--   * 'written_off' joins ('active','closed') in the principal subtraction: the
--     money left the pool and is never coming back.
--   * loan_recoveries add back the cash the negative savings_adjustments row
--     removes, because settling a debt from savings moves no actual cash.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_group_pool AS
SELECT
    (SELECT COALESCE(SUM(amount_claimed), 0)
       FROM payment_submissions
       WHERE submission_type = 'savings_deposit' AND status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM savings_adjustments WHERE status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM pool_adjustments    WHERE status = 'approved')
  + (SELECT COALESCE(SUM(amount), 0)
       FROM loan_recoveries)
  + (SELECT COALESCE(SUM(amount_paid), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM monthly_fees)
  + (SELECT COALESCE(SUM(interest_paid), 0)
           + COALESCE(SUM(principal_paid), 0)
           + COALESCE(SUM(penalty_collected), 0)
       FROM loan_installments)
  - (SELECT COALESCE(SUM(principal), 0)
       FROM loans             WHERE status IN ('active', 'closed', 'written_off'))
  AS pool_balance_tzs;

-- --------------------------------------------------------------------------
-- 3. v_loan_risk — non-performance derived from the record, never hand-set.
--    security_invoker so it inherits the loans/installments RLS: a member sees
--    only their own loan here, an admin sees every one.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_loan_risk
WITH (security_invoker = true) AS
SELECT
  l.id                        AS loan_id,
  l.member_id,
  l.principal,
  l.outstanding_principal,
  count(i.id)                 AS overdue_installments,
  min(i.due_date)             AS oldest_overdue,
  (today_eat() - min(i.due_date))::int AS days_overdue,
  COALESCE(SUM(i.penalty_due), 0)      AS penalty_accrued
FROM loans l
JOIN v_installment_status_money i ON i.loan_id = l.id
WHERE l.status = 'active'
  AND i.computed_status = 'overdue'
GROUP BY l.id, l.member_id, l.principal, l.outstanding_principal
HAVING count(i.id) >= 2;

GRANT SELECT ON v_loan_risk TO authenticated;

-- --------------------------------------------------------------------------
-- 4. Execution — runs only once the approval threshold is met.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION execute_loan_action(p_action_id uuid)
RETURNS void AS $$
DECLARE
  v_act         loan_actions%ROWTYPE;
  v_loan        loans%ROWTYPE;
  v_outstanding numeric(12,2);
  v_rate        numeric;
  v_int         numeric(12,2);
  v_next        int;
  v_n           int;
  v_amount      numeric(12,2);
  v_savings     numeric(14,2);
  v_title       text;
  v_body        text;
BEGIN
  SELECT * INTO v_act FROM loan_actions WHERE id = p_action_id FOR UPDATE;
  IF v_act.id IS NULL          THEN RAISE EXCEPTION 'Loan action not found'; END IF;
  IF v_act.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';     END IF;

  SELECT * INTO v_loan FROM loans WHERE id = v_act.loan_id FOR UPDATE;
  IF v_loan.id IS NULL          THEN RAISE EXCEPTION 'Loan not found';           END IF;
  IF v_loan.status <> 'active'  THEN RAISE EXCEPTION 'Loan is no longer active'; END IF;

  v_outstanding := v_loan.outstanding_principal;
  v_rate        := COALESCE(v_loan.interest_rate, 0.05);

  -- ------------------------------------------------------------- restructure
  IF v_act.action = 'restructure' THEN
    -- Untouched installments are cancelled (this is what stops the penalty clock);
    -- 'partial' rows are left alone so a member's part-payment is never erased.
    UPDATE loan_installments
       SET status = 'cancelled'
     WHERE loan_id = v_loan.id AND status = 'pending';

    SELECT COALESCE(max(installment_number), 0) INTO v_next
      FROM loan_installments WHERE loan_id = v_loan.id;

    v_int := round(v_outstanding * v_rate);
    FOR v_n IN 1..v_act.term_months LOOP
      INSERT INTO loan_installments
        (loan_id, installment_number, due_date, principal_due, interest_due, penalty_rate)
      VALUES (
        v_loan.id,
        v_next + v_n,
        (today_eat() + (v_n || ' month')::interval)::date,
        CASE WHEN v_n = v_act.term_months THEN v_outstanding ELSE 0 END,
        v_int,
        setting('penalty_rate')
      );
    END LOOP;

    v_title := 'Loan rescheduled';
    v_body  := 'Your loan has been rescheduled over ' || v_act.term_months ||
               ' month(s). See your updated repayment schedule.';

  -- --------------------------------------------------------------- write off
  ELSIF v_act.action = 'write_off' THEN
    UPDATE loans
       SET status = 'written_off', outstanding_principal = 0
     WHERE id = v_loan.id;
    UPDATE loan_installments
       SET status = 'cancelled'
     WHERE loan_id = v_loan.id AND status IN ('pending', 'partial');

    -- A negative earnings entry: the loss lands on the cycle in which the group
    -- decided to take it, so a share-out distributes profit net of write-offs.
    IF v_outstanding > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, source_type, source_id)
      VALUES (v_loan.member_id, 'write_off', -v_outstanding, 'loan', v_loan.id);
    END IF;
    v_outstanding := 0;

    v_title := 'Loan written off';
    v_body  := 'The group has written off the remaining balance of your loan.';

  -- ------------------------------------------------- recover from savings
  ELSE
    -- Never recover more than is owed, nor more than the member actually holds.
    SELECT
        COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                   WHERE member_id = v_loan.member_id
                     AND submission_type = 'savings_deposit'
                     AND status = 'approved'), 0)
      + COALESCE((SELECT SUM(amount_paid) FROM monthly_fees
                   WHERE member_id = v_loan.member_id), 0)
      + COALESCE((SELECT SUM(delta) FROM savings_adjustments
                   WHERE target_member_id = v_loan.member_id AND status = 'approved'), 0)
    INTO v_savings;

    v_amount := least(v_act.amount, v_outstanding, v_savings);
    IF v_amount <= 0 THEN
      RAISE EXCEPTION 'Nothing to recover: outstanding %, member savings %',
        v_outstanding, v_savings;
    END IF;

    -- The member's claim on the pool shrinks…
    INSERT INTO savings_adjustments
      (target_member_id, requested_by, delta, reason, status, applied_at)
    VALUES (v_loan.member_id, v_act.requested_by, -v_amount,
            'Loan recovery: ' || v_act.reason, 'approved', now());

    -- …and this cancels the cash movement that adjustment would otherwise imply.
    INSERT INTO loan_recoveries (loan_id, member_id, amount, action_id)
    VALUES (v_loan.id, v_loan.member_id, v_amount, v_act.id);

    v_outstanding := v_outstanding - v_amount;
    UPDATE loans SET outstanding_principal = v_outstanding WHERE id = v_loan.id;

    IF v_outstanding <= 0 THEN
      UPDATE loans SET status = 'closed' WHERE id = v_loan.id;
      UPDATE loan_installments
         SET status = 'cancelled'
       WHERE loan_id = v_loan.id AND status IN ('pending', 'partial');
    END IF;

    v_title := 'Loan settled from your savings';
    v_body  := v_amount || ' TZS of your savings was applied to your loan balance.';
  END IF;

  UPDATE loan_actions SET status = 'approved', applied_at = now() WHERE id = p_action_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'execute_loan_' || v_act.action, 'loan', v_loan.id,
          jsonb_build_object(
            'action_id',   p_action_id,
            'member_id',   v_loan.member_id,
            'principal',   v_loan.principal,
            'outstanding_before', v_loan.outstanding_principal,
            'outstanding_after',  v_outstanding,
            'amount',      v_act.amount,
            'term_months', v_act.term_months,
            'reason',      v_act.reason
          ));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_loan.member_id, 'loan_' || v_act.action, v_title, v_body,
          jsonb_build_object('loan_id', v_loan.id, 'action_id', p_action_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. Request / approve / cancel — same 2-of-N shape as pool edits (015).
--    The requester's vote does NOT auto-count, and an admin can never open or
--    approve an action against their OWN loan.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION request_loan_action(
  p_loan_id uuid, p_action text, p_reason text,
  p_amount numeric DEFAULT NULL, p_term_months int DEFAULT NULL
)
RETURNS uuid AS $$
DECLARE
  v_action_id    uuid;
  v_loan         loans%ROWTYPE;
  v_requester    text;
  v_member       text;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every loan action';
  END IF;
  IF p_action NOT IN ('restructure', 'write_off', 'recover_from_savings') THEN
    RAISE EXCEPTION 'Unknown loan action: %', p_action;
  END IF;

  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id;
  IF v_loan.id IS NULL         THEN RAISE EXCEPTION 'Loan not found';                  END IF;
  IF v_loan.status <> 'active' THEN RAISE EXCEPTION 'Only an active loan can be actioned'; END IF;
  IF v_loan.member_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot open an action against your own loan';
  END IF;

  IF p_action = 'restructure' THEN
    IF p_term_months IS NULL OR p_term_months < 1 OR p_term_months > 24 THEN
      RAISE EXCEPTION 'Term must be between 1 and 24 months';
    END IF;
  ELSIF p_action = 'recover_from_savings' THEN
    IF p_amount IS NULL OR p_amount <= 0 THEN
      RAISE EXCEPTION 'Enter the amount to recover';
    END IF;
  END IF;

  -- One open action per loan, so two admins can't approve conflicting outcomes.
  IF EXISTS (SELECT 1 FROM loan_actions WHERE loan_id = p_loan_id AND status = 'pending') THEN
    RAISE EXCEPTION 'This loan already has a pending action; cancel or approve it first';
  END IF;

  INSERT INTO loan_actions (loan_id, action, amount, term_months, reason, requested_by)
  VALUES (p_loan_id, p_action, p_amount, p_term_months, trim(p_reason), auth.uid())
  RETURNING id INTO v_action_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_loan_' || p_action, 'loan', p_loan_id,
          jsonb_build_object(
            'action_id',   v_action_id,
            'member_id',   v_loan.member_id,
            'amount',      p_amount,
            'term_months', p_term_months,
            'reason',      p_reason
          ));

  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  SELECT full_name INTO v_member    FROM profiles WHERE id = v_loan.member_id;
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'loan_action_requested',
         'Loan action proposed',
         COALESCE(v_requester, 'An admin') || ' proposed to ' ||
           replace(p_action, '_', ' ') || ' ' || COALESCE(v_member, 'a member') || '''s loan',
         jsonb_build_object('action_id', v_action_id, 'loan_id', p_loan_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles
   WHERE role = 'admin' AND is_active = true
     AND id <> auth.uid() AND id <> v_loan.member_id;
  v_required := least(2, v_other_admins);

  IF v_required = 0 THEN
    PERFORM execute_loan_action(v_action_id);
  END IF;

  RETURN v_action_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION approve_loan_action(p_action_id uuid)
RETURNS void AS $$
DECLARE
  v_act          loan_actions%ROWTYPE;
  v_borrower     uuid;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_act FROM loan_actions WHERE id = p_action_id FOR UPDATE;
  IF v_act.id IS NULL          THEN RAISE EXCEPTION 'Loan action not found';  END IF;
  IF v_act.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed'; END IF;
  IF v_act.requested_by = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;

  SELECT member_id INTO v_borrower FROM loans WHERE id = v_act.loan_id;
  IF v_borrower = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve an action on your own loan';
  END IF;

  BEGIN
    INSERT INTO loan_action_approvals (action_id, admin_id) VALUES (p_action_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this action';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles
   WHERE role = 'admin' AND is_active = true
     AND id <> v_act.requested_by AND id <> v_borrower;
  v_required := least(2, v_other_admins);

  SELECT count(*) INTO v_approvals FROM loan_action_approvals WHERE action_id = p_action_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_loan_action', 'loan', v_act.loan_id,
            jsonb_build_object(
              'action_id', p_action_id,
              'approvals', v_approvals,
              'required',  v_required
            ));
    RETURN;
  END IF;

  PERFORM execute_loan_action(p_action_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION cancel_loan_action(p_action_id uuid)
RETURNS void AS $$
DECLARE
  v_act loan_actions%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_act FROM loan_actions WHERE id = p_action_id;
  IF v_act.id IS NULL OR v_act.status <> 'pending' THEN RETURN; END IF;

  UPDATE loan_actions SET status = 'cancelled' WHERE id = p_action_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_loan_action', 'loan', v_act.loan_id,
          jsonb_build_object('action_id', p_action_id, 'action', v_act.action));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 023_cycles.sql
-- ---------------------------------------------------------------------------

-- 023_cycles.sql — the group finally has a financial year.
--
-- Until now money only ever flowed IN. Interest and penalties accumulated into one
-- anonymous pool figure and there was no way to say "this cycle we earned X, and
-- your share of it is Y". A SACCOS/VICOBA runs in cycles — typically twelve months
-- — and at the end distributes what it earned in proportion to what each member
-- had at risk. This migration defines the cycle and the attribution; 024 does the
-- distribution.
--
-- TIME-WEIGHTED, NOT CLOSING BALANCE. A member who deposits in month 11 must not
-- take the same share as one who carried the group from month 1. The basis is
-- member-months: each member's capital measured at every month-end in the cycle
-- and summed. `share_ratio = member basis / total basis`.
--
-- Capital is reconstructed from DATED events, never from a current balance:
--   * approved savings deposits            → reviewed_at
--   * the base (non-penalty) part of a fee → the fee submission's reviewed_at
--   * approved savings adjustments         → applied_at
-- The penalty part of a fee payment is subtracted using earnings_ledger (021),
-- because a fine is not the member's capital.
--
-- Requires 021 (earnings_ledger).

-- --------------------------------------------------------------------------
-- 1. cycles
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS cycles (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text NOT NULL,
  start_date date NOT NULL,
  end_date   date NOT NULL,
  status     text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  mode       text CHECK (mode IN ('earnings_only', 'full_shareout')),
  closed_at  timestamptz,
  closed_by  uuid REFERENCES profiles(id) ON DELETE SET NULL,
  CHECK (end_date > start_date)
);

-- Exactly one cycle can be open at a time. A partial unique index is the only way
-- to say that in the schema rather than hoping the RPCs remember.
CREATE UNIQUE INDEX IF NOT EXISTS cycles_single_open ON cycles ((status)) WHERE status = 'open';

ALTER TABLE cycles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Everyone reads cycles" ON cycles;
CREATE POLICY "Everyone reads cycles" ON cycles
  FOR SELECT USING (auth.uid() IS NOT NULL);

GRANT SELECT ON cycles TO authenticated;

-- Seed the first cycle from the group's actual history, so every existing fee,
-- deposit and repayment falls inside it rather than being stranded before cycle 1.
INSERT INTO cycles (name, start_date, end_date)
SELECT
  'Cycle 1',
  s.first_day,
  (s.first_day + INTERVAL '12 months' - INTERVAL '1 day')::date
FROM (
  SELECT COALESCE(
    least(
      (SELECT min(period)                  FROM monthly_fees),
      (SELECT min(submitted_at)::date      FROM payment_submissions),
      (SELECT min(created_at)::date        FROM profiles)
    ),
    today_eat()
  ) AS first_day
) s
WHERE NOT EXISTS (SELECT 1 FROM cycles);

-- --------------------------------------------------------------------------
-- 2. v_member_capital_events — every dated change to a member's capital.
--
--    security_invoker so it inherits the RLS of the tables underneath: a member
--    sees their own events, an admin sees everyone's.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_member_capital_events
WITH (security_invoker = true) AS
  -- Savings deposits, at the moment they were approved.
  SELECT
    ps.member_id,
    ps.amount_claimed          AS amount,
    COALESCE(ps.reviewed_at, ps.submitted_at) AS occurred_at,
    'deposit'::text            AS kind
  FROM payment_submissions ps
  WHERE ps.submission_type = 'savings_deposit' AND ps.status = 'approved'

  UNION ALL

  -- Monthly fee payments, minus the penalty portion — a fine is the group's
  -- income, not the payer's savings.
  SELECT
    ps.member_id,
    ps.amount_claimed - COALESCE(
      (SELECT SUM(el.amount) FROM earnings_ledger el
        WHERE el.submission_id = ps.id AND el.kind = 'penalty'), 0),
    COALESCE(ps.reviewed_at, ps.submitted_at),
    'fee'::text
  FROM payment_submissions ps
  WHERE ps.submission_type = 'monthly_fee' AND ps.status = 'approved'

  UNION ALL

  -- Corrective adjustments, including the negative ones a loan recovery writes.
  SELECT
    sa.target_member_id,
    sa.delta,
    COALESCE(sa.applied_at, sa.created_at),
    'adjustment'::text
  FROM savings_adjustments sa
  WHERE sa.status = 'approved';

GRANT SELECT ON v_member_capital_events TO authenticated;

-- --------------------------------------------------------------------------
-- 3. member_cycle_basis(cycle) — time-weighted member-months.
--
--    For each month-end inside the cycle, every member's capital as it stood on
--    that date; summed across the months that is the basis. Negative balances are
--    floored at zero so a member who has been overdrawn by an adjustment cannot
--    drag the denominator around.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION member_cycle_basis(p_cycle_id uuid)
RETURNS TABLE (
  member_id     uuid,
  basis         numeric,
  months        int,
  closing_capital numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH c AS (
    SELECT start_date, end_date FROM cycles WHERE id = p_cycle_id
  ),
  -- Month-end dates inside the cycle. The final point is the cycle's end_date
  -- itself, so a cycle that stops mid-month still counts that month.
  month_ends AS (
    SELECT least((date_trunc('month', d) + INTERVAL '1 month' - INTERVAL '1 day')::date,
                 (SELECT end_date FROM c)) AS as_of
    FROM c, generate_series(c.start_date, c.end_date, INTERVAL '1 month') d
  ),
  -- Active members only: someone who has exited (025) has already been settled.
  members AS (
    SELECT id FROM profiles WHERE is_active = true
  ),
  points AS (
    SELECT
      m.id AS member_id,
      me.as_of,
      greatest(COALESCE((
        SELECT SUM(e.amount)
        FROM v_member_capital_events e
        WHERE e.member_id = m.id
          AND e.occurred_at::date <= me.as_of
      ), 0), 0) AS capital
    FROM members m
    CROSS JOIN (SELECT DISTINCT as_of FROM month_ends) me
  )
  SELECT
    p.member_id,
    SUM(p.capital)                                             AS basis,
    count(*)::int                                              AS months,
    -- Capital as at the final measurement point = what they would take home if
    -- the group returns capital as well as earnings.
    max(p.capital) FILTER (WHERE p.as_of = (SELECT max(as_of) FROM month_ends)) AS closing_capital
  FROM points p
  GROUP BY p.member_id;
$$;

GRANT EXECUTE ON FUNCTION member_cycle_basis(uuid) TO authenticated;

-- --------------------------------------------------------------------------
-- 4. cycle_earnings(cycle) — what the group made, net of losses.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cycle_earnings(p_cycle_id uuid)
RETURNS TABLE (
  interest_tzs  numeric,
  penalty_tzs   numeric,
  write_off_tzs numeric,
  net_tzs       numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    COALESCE(SUM(amount) FILTER (WHERE kind = 'interest'),  0),
    COALESCE(SUM(amount) FILTER (WHERE kind = 'penalty'),   0),
    COALESCE(SUM(amount) FILTER (WHERE kind = 'write_off'), 0),
    COALESCE(SUM(amount), 0)
  FROM earnings_ledger el, cycles c
  WHERE c.id = p_cycle_id
    AND el.occurred_at::date BETWEEN c.start_date AND c.end_date;
$$;

GRANT EXECUTE ON FUNCTION cycle_earnings(uuid) TO authenticated;

-- --------------------------------------------------------------------------
-- 5. Admin: adjust the open cycle's dates (2-of-N is overkill here — no money
--    moves until close_cycle runs, which IS 2-of-N).
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION update_cycle_dates(
  p_cycle_id uuid, p_start date, p_end date, p_name text
)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_end <= p_start THEN RAISE EXCEPTION 'The cycle must end after it starts'; END IF;
  IF (SELECT status FROM cycles WHERE id = p_cycle_id) <> 'open' THEN
    RAISE EXCEPTION 'A closed cycle can no longer be edited';
  END IF;

  UPDATE cycles
     SET start_date = p_start, end_date = p_end, name = COALESCE(NULLIF(trim(p_name), ''), name)
   WHERE id = p_cycle_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'update_cycle_dates', 'cycle', p_cycle_id,
          jsonb_build_object('start_date', p_start, 'end_date', p_end));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 024_share_out.sql
-- ---------------------------------------------------------------------------

-- 024_share_out.sql — closing a cycle and paying everyone their share.
--
-- close_cycle() freezes the arithmetic into `distributions` rows: each member's
-- time-weighted basis, their share ratio, their slice of the group's earnings and
-- (in full_shareout mode) their capital back. SNAPSHOTTING IS THE POINT — once the
-- group has agreed a share-out, a later savings correction must not silently
-- restate what everyone was told they would receive.
--
-- Two modes:
--   earnings_only  profit is paid out, capital rolls into the next cycle. The
--                  common choice for a group that wants to keep lending.
--   full_shareout  profit AND capital go back; everyone starts the next cycle at
--                  zero. The classic VICOBA year-end.
--
-- ROUNDING uses largest-remainder: every share is floored to whole shillings and
-- the leftover shillings go to the largest fractional parts. The shares therefore
-- sum EXACTLY to the pot — no stray shilling, no member quietly short-changed.
--
-- A LOSS YEAR pays no earnings (shares are floored at zero) rather than billing
-- members for a negative share. The loss already reduced the pool when it was
-- recognised. In full_shareout mode the pool must actually cover the payout, and
-- close_cycle refuses with the shortfall if it does not — the admins then have to
-- allocate the loss explicitly (a savings or pool edit) before closing.
--
-- Requires 023.

-- --------------------------------------------------------------------------
-- 1. Schema
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS distributions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cycle_id             uuid NOT NULL REFERENCES cycles(id) ON DELETE CASCADE,
  member_id            uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  basis_amount         numeric(16,2) NOT NULL,
  share_ratio          numeric(12,10) NOT NULL,
  earnings_tzs         numeric(14,2) NOT NULL DEFAULT 0,
  capital_returned_tzs numeric(14,2) NOT NULL DEFAULT 0,
  total_payout_tzs     numeric(14,2) NOT NULL DEFAULT 0,
  status               text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid')),
  paid_at              timestamptz,
  paid_by              uuid REFERENCES profiles(id) ON DELETE SET NULL,
  proof_url            text,
  UNIQUE (cycle_id, member_id)
);
CREATE INDEX IF NOT EXISTS distributions_member_idx ON distributions (member_id);

-- 2-of-N approval to close a cycle, same shape as pool edits (015).
CREATE TABLE IF NOT EXISTS cycle_closures (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cycle_id     uuid NOT NULL REFERENCES cycles(id) ON DELETE CASCADE,
  mode         text NOT NULL CHECK (mode IN ('earnings_only', 'full_shareout')),
  reason       text NOT NULL,
  requested_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
  status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'cancelled')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  applied_at   timestamptz
);

CREATE TABLE IF NOT EXISTS cycle_closure_approvals (
  closure_id  uuid NOT NULL REFERENCES cycle_closures(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (closure_id, admin_id)
);

ALTER TABLE distributions           ENABLE ROW LEVEL SECURITY;
ALTER TABLE cycle_closures          ENABLE ROW LEVEL SECURITY;
ALTER TABLE cycle_closure_approvals ENABLE ROW LEVEL SECURITY;

-- A share-out is the group's business: everyone sees everyone's share. That is
-- the same transparency stance as the member directory (019), and it is the only
-- way members can check the split adds up.
DROP POLICY IF EXISTS "Everyone reads distributions" ON distributions;
CREATE POLICY "Everyone reads distributions" ON distributions
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Everyone reads cycle closures" ON cycle_closures;
CREATE POLICY "Everyone reads cycle closures" ON cycle_closures
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Admins read closure approvals" ON cycle_closure_approvals;
CREATE POLICY "Admins read closure approvals" ON cycle_closure_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON distributions, cycle_closures, cycle_closure_approvals TO authenticated;

-- --------------------------------------------------------------------------
-- 2. v_group_pool — a paid-out earnings share is cash leaving the group.
--
--    The CAPITAL half of a payout is not subtracted here: mark_distribution_paid
--    writes a negative savings_adjustments row for it, which this view already
--    counts. Subtracting both would take the money out twice.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_group_pool AS
SELECT
    (SELECT COALESCE(SUM(amount_claimed), 0)
       FROM payment_submissions
       WHERE submission_type = 'savings_deposit' AND status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM savings_adjustments WHERE status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM pool_adjustments    WHERE status = 'approved')
  + (SELECT COALESCE(SUM(amount), 0)
       FROM loan_recoveries)
  + (SELECT COALESCE(SUM(amount_paid), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM monthly_fees)
  + (SELECT COALESCE(SUM(interest_paid), 0)
           + COALESCE(SUM(principal_paid), 0)
           + COALESCE(SUM(penalty_collected), 0)
       FROM loan_installments)
  - (SELECT COALESCE(SUM(principal), 0)
       FROM loans             WHERE status IN ('active', 'closed', 'written_off'))
  - (SELECT COALESCE(SUM(earnings_tzs), 0)
       FROM distributions     WHERE status = 'paid')
  AS pool_balance_tzs;

-- --------------------------------------------------------------------------
-- 3. preview_cycle_close — exactly what close_cycle will write, without writing
--    it. The admin wizard renders this table before anyone votes.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION preview_cycle_close(p_cycle_id uuid, p_mode text)
RETURNS TABLE (
  member_id            uuid,
  full_name            text,
  basis_amount         numeric,
  share_ratio          numeric,
  earnings_tzs         numeric,
  capital_returned_tzs numeric,
  total_payout_tzs     numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH b AS (
    SELECT * FROM member_cycle_basis(p_cycle_id)
  ),
  totals AS (
    SELECT
      tb.total_basis,
      -- Floored to whole shillings so the largest-remainder pass below distributes
      -- an integer pot and the shares can sum to it exactly. With no basis at all
      -- nobody has a proportional claim, so the pot stays in the pool instead of
      -- the remainder pass handing shillings to members who contributed nothing.
      CASE WHEN tb.total_basis > 0
           THEN floor(greatest((SELECT net_tzs FROM cycle_earnings(p_cycle_id)), 0))
           ELSE 0 END AS pot
    FROM (SELECT COALESCE(SUM(basis), 0) AS total_basis FROM b) tb
  ),
  raw AS (
    SELECT
      b.member_id,
      b.basis,
      b.closing_capital,
      CASE WHEN t.total_basis > 0 THEN b.basis / t.total_basis ELSE 0 END AS ratio,
      CASE WHEN t.total_basis > 0 THEN t.pot * b.basis / t.total_basis ELSE 0 END AS exact_share,
      t.pot
    FROM b CROSS JOIN totals t
  ),
  -- Largest remainder: floor everyone, then hand the leftover shillings to the
  -- biggest fractional parts so the shares sum exactly to the pot.
  ranked AS (
    SELECT
      raw.*,
      floor(exact_share) AS base_share,
      row_number() OVER (ORDER BY exact_share - floor(exact_share) DESC, member_id) AS rn,
      (SELECT pot FROM totals) - (SELECT COALESCE(SUM(floor(exact_share)), 0) FROM raw) AS leftover
    FROM raw
  )
  SELECT
    r.member_id,
    p.full_name,
    r.basis,
    r.ratio,
    (r.base_share + CASE WHEN r.rn <= r.leftover THEN 1 ELSE 0 END)::numeric AS earnings_tzs,
    CASE WHEN p_mode = 'full_shareout' THEN COALESCE(r.closing_capital, 0) ELSE 0 END,
    (r.base_share + CASE WHEN r.rn <= r.leftover THEN 1 ELSE 0 END)
      + CASE WHEN p_mode = 'full_shareout' THEN COALESCE(r.closing_capital, 0) ELSE 0 END
  FROM ranked r
  JOIN profiles p ON p.id = r.member_id
  ORDER BY p.full_name;
$$;

GRANT EXECUTE ON FUNCTION preview_cycle_close(uuid, text) TO authenticated;

-- --------------------------------------------------------------------------
-- 4. Execution
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION execute_cycle_close(p_closure_id uuid)
RETURNS void AS $$
DECLARE
  v_closure  cycle_closures%ROWTYPE;
  v_cycle    cycles%ROWTYPE;
  v_pool     numeric(14,2);
  v_payout   numeric(14,2);
  v_next_end date;
BEGIN
  SELECT * INTO v_closure FROM cycle_closures WHERE id = p_closure_id FOR UPDATE;
  IF v_closure.id IS NULL          THEN RAISE EXCEPTION 'Closure request not found'; END IF;
  IF v_closure.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';         END IF;

  SELECT * INTO v_cycle FROM cycles WHERE id = v_closure.cycle_id FOR UPDATE;
  IF v_cycle.status <> 'open' THEN RAISE EXCEPTION 'This cycle is already closed'; END IF;

  -- Freeze the numbers.
  INSERT INTO distributions
    (cycle_id, member_id, basis_amount, share_ratio, earnings_tzs,
     capital_returned_tzs, total_payout_tzs)
  SELECT
    v_cycle.id, member_id, basis_amount, share_ratio, earnings_tzs,
    capital_returned_tzs, total_payout_tzs
  FROM preview_cycle_close(v_cycle.id, v_closure.mode)
  WHERE total_payout_tzs > 0;

  SELECT COALESCE(SUM(total_payout_tzs), 0) INTO v_payout
    FROM distributions WHERE cycle_id = v_cycle.id;
  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;

  IF v_payout > v_pool THEN
    RAISE EXCEPTION
      'The payout of % exceeds the pool of % (short by %). Settle outstanding loans or allocate the shortfall before closing.',
      v_payout, v_pool, v_payout - v_pool;
  END IF;

  UPDATE cycles
     SET status = 'closed', mode = v_closure.mode, closed_at = now(), closed_by = auth.uid()
   WHERE id = v_cycle.id;

  UPDATE cycle_closures SET status = 'approved', applied_at = now() WHERE id = p_closure_id;

  -- Open the next cycle immediately: the group keeps running, and every fee and
  -- deposit from tomorrow needs a cycle to belong to.
  v_next_end := ((v_cycle.end_date + 1) + INTERVAL '12 months' - INTERVAL '1 day')::date;
  INSERT INTO cycles (name, start_date, end_date)
  VALUES (
    'Cycle ' || (SELECT count(*) + 1 FROM cycles),
    v_cycle.end_date + 1,
    v_next_end
  );

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'close_cycle', 'cycle', v_cycle.id,
          jsonb_build_object(
            'mode',        v_closure.mode,
            'total_payout', v_payout,
            'members',     (SELECT count(*) FROM distributions WHERE cycle_id = v_cycle.id),
            'reason',      v_closure.reason
          ));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT d.member_id, 'share_out_ready',
         'Your share-out is ready',
         'The group closed ' || v_cycle.name || '. Your share is ' || d.total_payout_tzs || ' TZS.',
         jsonb_build_object('cycle_id', v_cycle.id, 'distribution_id', d.id)
    FROM distributions d WHERE d.cycle_id = v_cycle.id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION request_cycle_close(p_cycle_id uuid, p_mode text, p_reason text)
RETURNS uuid AS $$
DECLARE
  v_closure_id   uuid;
  v_cycle        cycles%ROWTYPE;
  v_open_loans   int;
  v_open_subs    int;
  v_requester    text;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_mode NOT IN ('earnings_only', 'full_shareout') THEN
    RAISE EXCEPTION 'Unknown share-out mode: %', p_mode;
  END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required to close a cycle';
  END IF;

  SELECT * INTO v_cycle FROM cycles WHERE id = p_cycle_id;
  IF v_cycle.id IS NULL       THEN RAISE EXCEPTION 'Cycle not found';           END IF;
  IF v_cycle.status <> 'open' THEN RAISE EXCEPTION 'This cycle is already closed'; END IF;

  -- Nothing may be in flight: a submission approved mid-close would land in a
  -- cycle whose numbers are already frozen.
  SELECT count(*) INTO v_open_subs FROM payment_submissions WHERE status = 'pending';
  IF v_open_subs > 0 THEN
    RAISE EXCEPTION 'Clear the % pending payment(s) before closing the cycle', v_open_subs;
  END IF;

  SELECT count(*) INTO v_open_loans FROM loans WHERE status IN ('pending', 'active');
  IF v_open_loans > 0 AND p_mode = 'full_shareout' THEN
    RAISE EXCEPTION
      'Cannot return everyone''s capital while % loan(s) are still out. Settle or write them off first, or close with earnings only.',
      v_open_loans;
  END IF;

  IF EXISTS (SELECT 1 FROM cycle_closures WHERE cycle_id = p_cycle_id AND status = 'pending') THEN
    RAISE EXCEPTION 'A closure request for this cycle is already open';
  END IF;

  INSERT INTO cycle_closures (cycle_id, mode, reason, requested_by)
  VALUES (p_cycle_id, p_mode, trim(p_reason), auth.uid())
  RETURNING id INTO v_closure_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_cycle_close', 'cycle', p_cycle_id,
          jsonb_build_object('closure_id', v_closure_id, 'mode', p_mode, 'reason', p_reason));

  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'cycle_close_requested',
         'Cycle close proposed',
         COALESCE(v_requester, 'An admin') || ' proposed to close ' || v_cycle.name,
         jsonb_build_object('closure_id', v_closure_id, 'cycle_id', p_cycle_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  v_required := least(2, v_other_admins);

  IF v_required = 0 THEN
    PERFORM execute_cycle_close(v_closure_id);
  END IF;

  RETURN v_closure_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION approve_cycle_close(p_closure_id uuid)
RETURNS void AS $$
DECLARE
  v_closure      cycle_closures%ROWTYPE;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_closure FROM cycle_closures WHERE id = p_closure_id FOR UPDATE;
  IF v_closure.id IS NULL          THEN RAISE EXCEPTION 'Closure request not found'; END IF;
  IF v_closure.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed'; END IF;
  IF v_closure.requested_by = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;

  BEGIN
    INSERT INTO cycle_closure_approvals (closure_id, admin_id) VALUES (p_closure_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this closure';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_closure.requested_by;
  v_required := least(2, v_other_admins);

  SELECT count(*) INTO v_approvals FROM cycle_closure_approvals WHERE closure_id = p_closure_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_cycle_close', 'cycle', v_closure.cycle_id,
            jsonb_build_object('closure_id', p_closure_id,
                               'approvals', v_approvals, 'required', v_required));
    RETURN;
  END IF;

  PERFORM execute_cycle_close(p_closure_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION cancel_cycle_close(p_closure_id uuid)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE cycle_closures SET status = 'cancelled'
   WHERE id = p_closure_id AND status = 'pending';
  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_cycle_close', 'cycle', NULL,
          jsonb_build_object('closure_id', p_closure_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. mark_distribution_paid — record the actual payout, with its M-Pesa proof.
--
--    The capital half is written back as a negative savings adjustment, so the
--    member's savings, the transparency directory and the pool all fall together
--    without any of them needing to know that a share-out happened.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION mark_distribution_paid(p_distribution_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_dist  distributions%ROWTYPE;
  v_pool  numeric(14,2);
  v_cycle text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_dist FROM distributions WHERE id = p_distribution_id FOR UPDATE;
  IF v_dist.id IS NULL          THEN RAISE EXCEPTION 'Distribution not found'; END IF;
  IF v_dist.status = 'paid'     THEN RAISE EXCEPTION 'Already paid out';       END IF;
  IF v_dist.member_id = auth.uid() THEN
    RAISE EXCEPTION 'Another admin must record your own payout';
  END IF;

  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;
  IF v_dist.total_payout_tzs > v_pool THEN
    RAISE EXCEPTION 'The pool holds only % — not enough to pay %', v_pool, v_dist.total_payout_tzs;
  END IF;

  UPDATE distributions
     SET status = 'paid', paid_at = now(), paid_by = auth.uid(), proof_url = p_proof_url
   WHERE id = p_distribution_id;

  SELECT name INTO v_cycle FROM cycles WHERE id = v_dist.cycle_id;

  IF v_dist.capital_returned_tzs > 0 THEN
    INSERT INTO savings_adjustments
      (target_member_id, requested_by, delta, reason, status, applied_at)
    VALUES (v_dist.member_id, auth.uid(), -v_dist.capital_returned_tzs,
            'Capital returned at share-out (' || COALESCE(v_cycle, 'cycle') || ')',
            'approved', now());
  END IF;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'mark_distribution_paid', 'distribution', p_distribution_id,
          jsonb_build_object(
            'member_id', v_dist.member_id,
            'earnings',  v_dist.earnings_tzs,
            'capital',   v_dist.capital_returned_tzs,
            'total',     v_dist.total_payout_tzs
          ));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_dist.member_id, 'share_out_paid', 'Share-out paid',
          v_dist.total_payout_tzs || ' TZS has been paid out to you.',
          jsonb_build_object('distribution_id', p_distribution_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 025_withdrawals_and_exit.sql
-- ---------------------------------------------------------------------------

-- 025_withdrawals_and_exit.sql — a way out that isn't deletion.
--
-- Two gaps this closes:
--
--   1. A member could deposit forever and never withdraw a shilling mid-cycle.
--   2. The only way to remove someone was request_member_deletion, which WIPES
--      their financial history — useful for an account created in error, terrible
--      for a member who simply leaves. request_member_exit settles them and
--      deactivates them, keeping every record intact.
--
-- Withdrawals get their own table rather than a fourth payment_submissions type:
-- money going OUT has a different approval shape (the proof is attached at payout,
-- by the admin, not at request time by the member) and different guards.
--
-- THE COLLATERAL GUARD is the important one. Loans are capped at
-- `contribution_multiplier x savings` (020), so savings are effectively the
-- security behind an active loan. A borrower may therefore only withdraw down to
-- `outstanding / multiplier` — withdrawing more would leave a loan the group would
-- never have approved in the first place.
--
-- Requires 024.

-- --------------------------------------------------------------------------
-- 1. Schema
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS withdrawal_requests (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  amount       numeric(12,2) NOT NULL CHECK (amount > 0),
  reason       text NOT NULL,
  status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'rejected', 'paid')),
  is_exit      boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now(),
  approved_at  timestamptz,
  paid_at      timestamptz,
  paid_by      uuid REFERENCES profiles(id) ON DELETE SET NULL,
  proof_url    text,
  rejection_reason text
);
CREATE INDEX IF NOT EXISTS withdrawal_requests_status_idx
  ON withdrawal_requests (status, created_at DESC);

CREATE TABLE IF NOT EXISTS withdrawal_approvals (
  request_id  uuid NOT NULL REFERENCES withdrawal_requests(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, admin_id)
);

ALTER TABLE withdrawal_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE withdrawal_approvals ENABLE ROW LEVEL SECURITY;

-- Withdrawals move group money, so the group sees them — same transparency stance
-- as the member directory (019) and the share-out (024).
DROP POLICY IF EXISTS "Everyone reads withdrawals" ON withdrawal_requests;
CREATE POLICY "Everyone reads withdrawals" ON withdrawal_requests
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Admins read withdrawal approvals" ON withdrawal_approvals;
CREATE POLICY "Admins read withdrawal approvals" ON withdrawal_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON withdrawal_requests, withdrawal_approvals TO authenticated;

-- --------------------------------------------------------------------------
-- 2. member_withdrawable(member) — the single source of truth for the ceiling,
--    used by the request RPC, the approval RPC and the member's own form.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION member_withdrawable(p_member_id uuid)
RETURNS TABLE (
  savings_tzs     numeric,
  outstanding_tzs numeric,
  locked_tzs      numeric,
  pool_tzs        numeric,
  withdrawable_tzs numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH s AS (
    SELECT
        COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                   WHERE member_id = p_member_id
                     AND submission_type = 'savings_deposit'
                     AND status = 'approved'), 0)
      + COALESCE((SELECT SUM(amount_paid) FROM monthly_fees
                   WHERE member_id = p_member_id), 0)
      + COALESCE((SELECT SUM(delta) FROM savings_adjustments
                   WHERE target_member_id = p_member_id AND status = 'approved'), 0)
      -- Money already committed to a withdrawal that hasn't been paid yet is not
      -- available again, or a member could drain the pool with parallel requests.
      - COALESCE((SELECT SUM(amount) FROM withdrawal_requests
                   WHERE member_id = p_member_id AND status IN ('pending', 'approved')), 0)
        AS savings,
      COALESCE((SELECT SUM(COALESCE(outstanding_principal, principal))
                  FROM loans WHERE member_id = p_member_id AND status = 'active'), 0)
        AS outstanding,
      (SELECT pool_balance_tzs FROM v_group_pool) AS pool
  )
  SELECT
    s.savings,
    s.outstanding,
    -- Savings held as security behind the active loan.
    CASE WHEN s.outstanding > 0
         THEN ceil(s.outstanding / greatest(setting('contribution_multiplier'), 1))
         ELSE 0 END,
    s.pool,
    greatest(
      least(
        s.savings - CASE WHEN s.outstanding > 0
                         THEN ceil(s.outstanding / greatest(setting('contribution_multiplier'), 1))
                         ELSE 0 END,
        s.pool
      ),
      0
    )
  FROM s;
$$;

GRANT EXECUTE ON FUNCTION member_withdrawable(uuid) TO authenticated;

-- --------------------------------------------------------------------------
-- 3. Member: open a withdrawal request.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION request_withdrawal(p_amount numeric, p_reason text)
RETURNS uuid AS $$
DECLARE
  v_id      uuid;
  v_max     numeric(14,2);
  v_name    text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND is_active = true) THEN
    RAISE EXCEPTION 'Your membership is not active';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Enter an amount greater than zero'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every withdrawal';
  END IF;

  IF EXISTS (SELECT 1 FROM withdrawal_requests
              WHERE member_id = auth.uid() AND status IN ('pending', 'approved')) THEN
    RAISE EXCEPTION 'You already have a withdrawal in progress';
  END IF;

  SELECT withdrawable_tzs INTO v_max FROM member_withdrawable(auth.uid());
  IF p_amount > v_max THEN
    RAISE EXCEPTION 'You can withdraw at most % right now', v_max;
  END IF;

  INSERT INTO withdrawal_requests (member_id, amount, reason)
  VALUES (auth.uid(), p_amount, trim(p_reason))
  RETURNING id INTO v_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_withdrawal', 'withdrawal', v_id,
          jsonb_build_object('amount', p_amount, 'reason', p_reason));

  SELECT full_name INTO v_name FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'withdrawal_requested',
         'Withdrawal requested',
         COALESCE(v_name, 'A member') || ' wants to withdraw ' || p_amount || ' TZS',
         jsonb_build_object('request_id', v_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 4. Admin: approve (2-of-N), reject, and record the payout.
--
--    Approval only authorises the payment. The money — and the member's savings —
--    move at mark_withdrawal_paid, when the M-Pesa proof exists.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_withdrawal(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_req          withdrawal_requests%ROWTYPE;
  v_max          numeric(14,2);
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_req FROM withdrawal_requests WHERE id = p_request_id FOR UPDATE;
  IF v_req.id IS NULL          THEN RAISE EXCEPTION 'Withdrawal not found';    END IF;
  IF v_req.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';       END IF;
  IF v_req.member_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own withdrawal';
  END IF;

  BEGIN
    INSERT INTO withdrawal_approvals (request_id, admin_id) VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this withdrawal';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_req.member_id;
  v_required := least(2, v_other_admins);

  SELECT count(*) INTO v_approvals FROM withdrawal_approvals WHERE request_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_withdrawal', 'withdrawal', p_request_id,
            jsonb_build_object('approvals', v_approvals, 'required', v_required));
    RETURN;
  END IF;

  -- Re-check the ceiling at the moment of approval: the pool and the member's
  -- balance may both have moved since the request was opened. The request's own
  -- amount is excluded from the "committed" subtraction inside member_withdrawable
  -- by adding it back here.
  SELECT withdrawable_tzs + v_req.amount INTO v_max FROM member_withdrawable(v_req.member_id);
  IF v_req.amount > v_max THEN
    RAISE EXCEPTION 'Only % can be withdrawn now — the pool or their balance has changed', v_max;
  END IF;

  UPDATE withdrawal_requests
     SET status = 'approved', approved_at = now()
   WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_withdrawal', 'withdrawal', p_request_id,
          jsonb_build_object('member_id', v_req.member_id, 'amount', v_req.amount));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_req.member_id, 'withdrawal_approved', 'Withdrawal approved',
          'Your withdrawal of ' || v_req.amount || ' TZS was approved and will be paid out.',
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION reject_withdrawal(p_request_id uuid, p_reason text)
RETURNS void AS $$
DECLARE
  v_req withdrawal_requests%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_req FROM withdrawal_requests WHERE id = p_request_id;
  IF v_req.id IS NULL OR v_req.status NOT IN ('pending', 'approved') THEN RETURN; END IF;

  UPDATE withdrawal_requests
     SET status = 'rejected', rejection_reason = p_reason
   WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'reject_withdrawal', 'withdrawal', p_request_id,
          jsonb_build_object('member_id', v_req.member_id, 'reason', p_reason));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_req.member_id, 'withdrawal_rejected', 'Withdrawal rejected',
          COALESCE(p_reason, 'Your withdrawal request was rejected.'),
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- The money actually leaves here. The negative savings adjustment is what makes
-- the member's balance, the transparency directory and the pool all fall together.
CREATE OR REPLACE FUNCTION mark_withdrawal_paid(p_request_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_req  withdrawal_requests%ROWTYPE;
  v_pool numeric(14,2);
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_req FROM withdrawal_requests WHERE id = p_request_id FOR UPDATE;
  IF v_req.id IS NULL           THEN RAISE EXCEPTION 'Withdrawal not found';        END IF;
  IF v_req.status <> 'approved' THEN RAISE EXCEPTION 'This withdrawal is not approved'; END IF;
  IF v_req.member_id = auth.uid() THEN
    RAISE EXCEPTION 'Another admin must record your own payout';
  END IF;

  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;
  IF v_req.amount > v_pool THEN
    RAISE EXCEPTION 'The pool holds only % — not enough to pay %', v_pool, v_req.amount;
  END IF;

  UPDATE withdrawal_requests
     SET status = 'paid', paid_at = now(), paid_by = auth.uid(), proof_url = p_proof_url
   WHERE id = p_request_id;

  INSERT INTO savings_adjustments
    (target_member_id, requested_by, delta, reason, status, applied_at)
  VALUES (v_req.member_id, auth.uid(), -v_req.amount,
          CASE WHEN v_req.is_exit THEN 'Exit settlement' ELSE 'Withdrawal' END ||
            ': ' || v_req.reason,
          'approved', now());

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'mark_withdrawal_paid', 'withdrawal', p_request_id,
          jsonb_build_object('member_id', v_req.member_id, 'amount', v_req.amount,
                             'is_exit', v_req.is_exit));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_req.member_id, 'withdrawal_paid', 'Withdrawal paid',
          v_req.amount || ' TZS has been paid out to you.',
          jsonb_build_object('request_id', p_request_id));

  -- An exit settlement is the member's last act in the group.
  IF v_req.is_exit THEN
    UPDATE profiles SET is_active = false WHERE id = v_req.member_id;
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'member_exited', 'member', v_req.member_id,
            jsonb_build_object('settlement', v_req.amount));
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. Member exit — settle and deactivate, KEEPING the history.
--
--    Deliberately distinct from request_member_deletion (010), which erases
--    everything. Exit opens a withdrawal for the member's whole remaining balance;
--    paying it out deactivates them. Every fee, loan and repayment stays on record
--    so past cycles still reconcile.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION request_member_exit(p_member_id uuid, p_reason text)
RETURNS uuid AS $$
DECLARE
  v_id          uuid;
  v_settlement  numeric(14,2);
  v_outstanding numeric(14,2);
  v_name        text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required to exit a member';
  END IF;
  IF p_member_id = auth.uid() THEN
    RAISE EXCEPTION 'Another admin must process your own exit';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_member_id AND is_active = true) THEN
    RAISE EXCEPTION 'That member is not active';
  END IF;

  -- The group cannot let someone walk away from an open loan. Settle it, write it
  -- off, or recover it from their savings first (all in 022).
  SELECT COALESCE(SUM(COALESCE(outstanding_principal, principal)), 0) INTO v_outstanding
    FROM loans WHERE member_id = p_member_id AND status IN ('pending', 'active');
  IF v_outstanding > 0 THEN
    RAISE EXCEPTION
      'This member still owes %. Settle, recover from savings, or write off the loan before they exit.',
      v_outstanding;
  END IF;

  IF EXISTS (SELECT 1 FROM withdrawal_requests
              WHERE member_id = p_member_id AND status IN ('pending', 'approved')) THEN
    RAISE EXCEPTION 'That member already has a withdrawal in progress';
  END IF;

  SELECT withdrawable_tzs INTO v_settlement FROM member_withdrawable(p_member_id);
  IF v_settlement <= 0 THEN
    RAISE EXCEPTION 'There is nothing to settle — deactivate the member instead';
  END IF;

  INSERT INTO withdrawal_requests (member_id, amount, reason, is_exit)
  VALUES (p_member_id, v_settlement, trim(p_reason), true)
  RETURNING id INTO v_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_member_exit', 'member', p_member_id,
          jsonb_build_object('request_id', v_id, 'settlement', v_settlement, 'reason', p_reason));

  SELECT full_name INTO v_name FROM profiles WHERE id = p_member_id;
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'member_exit_requested',
         'Member exit proposed',
         COALESCE(v_name, 'A member') || ' would be settled for ' || v_settlement || ' TZS and leave the group',
         jsonb_build_object('request_id', v_id, 'member_id', p_member_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 026_notification_delivery.sql
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- 027_reconciliation.sql
-- ---------------------------------------------------------------------------

-- 027_reconciliation.sql — prove the books balance, and make the views scope the
-- way the comments always claimed they did.
--
-- TWO UNRELATED FIXES, both about trusting what the app displays.
--
-- 1. RECONCILIATION. v_group_pool is now a ten-term expression over eight tables,
--    rewritten three times (021 cash correction, 022 write-offs and recoveries,
--    024 distributions). Nothing checks it against anything. A drift would surface
--    as a number that is quietly wrong — the worst kind of bug in a system whose
--    only product is numbers members trust.
--
--    So compute the group's worth a second way, from an independent direction, and
--    compare. Assets and claims must agree:
--
--      ASSETS  = liquid pool + principal still out on active loans
--      CLAIMS  = member capital + retained earnings − earnings already paid out
--
--    Where member capital is what members put in (deposits + fee base + approved
--    adjustments) and retained earnings is everything the group made (interest +
--    penalties − write-offs). The two are derived from different tables by
--    different paths, so agreement is meaningful; a non-zero difference means a
--    money path exists that one of them does not know about.
--
-- 2. security_invoker. 003_rls_policies.sql:50 says the status/money views scope
--    per member "(security_invoker default)". That is backwards: Postgres views
--    default to security_invoker = FALSE and run with the OWNER's rights, which
--    bypasses RLS on the tables underneath. On a project where the views are owned
--    by a privileged role, any member could read every other member's fee and
--    installment rows straight out of v_fee_status_money. This sets the flag the
--    comment always assumed, and 05_guards.test.sql asserts it from now on.

-- --------------------------------------------------------------------------
-- 1. security_invoker on the member-scoped views.
--
--    The policies underneath are already `own row OR is_admin()`, so admins keep
--    seeing everything and members see themselves. The SECURITY DEFINER RPCs
--    (approve_submission, approve_loan, the cycle functions) run as their owner
--    and are unaffected.
--
--    v_group_pool and v_group_assets are deliberately LEFT ALONE: they are single
--    aggregates over the whole group with no per-member rows to leak, every member
--    is entitled to see them, and they are read inside SECURITY DEFINER functions
--    that must not be subject to the caller's RLS.
-- --------------------------------------------------------------------------

ALTER VIEW v_fee_status                SET (security_invoker = true);
ALTER VIEW v_fee_status_money          SET (security_invoker = true);
ALTER VIEW v_installment_status        SET (security_invoker = true);
ALTER VIEW v_installment_status_money  SET (security_invoker = true);

-- --------------------------------------------------------------------------
-- 2. The identity, one component per row so a mismatch says WHERE it is.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_pool_reconciliation AS
WITH
  -- What members have put in and not taken out. Withdrawals and returned capital
  -- both land here as negative savings_adjustments, so this needs no special case.
  capital AS (
    SELECT
        COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                   WHERE submission_type = 'savings_deposit' AND status = 'approved'), 0)
      + COALESCE((SELECT SUM(amount_paid) FROM monthly_fees), 0)
      + COALESCE((SELECT SUM(delta) FROM savings_adjustments WHERE status = 'approved'), 0)
      AS member_capital
  ),
  -- What the group has earned over its whole life, less what it has paid out.
  earnings AS (
    SELECT
        COALESCE((SELECT SUM(amount) FROM earnings_ledger), 0)
      - COALESCE((SELECT SUM(earnings_tzs) FROM distributions WHERE status = 'paid'), 0)
      AS retained_earnings
  ),
  -- Admin corrections to the pool that are not attributable to any member. A
  -- legitimate part of the group's worth, so the identity has to include them or
  -- every pool edit would look like a discrepancy.
  adjustments AS (
    SELECT COALESCE((SELECT SUM(delta) FROM pool_adjustments WHERE status = 'approved'), 0)
      AS pool_adjustments_tzs
  ),
  assets AS (
    SELECT
      (SELECT pool_balance_tzs FROM v_group_pool) AS pool_tzs,
      COALESCE((SELECT SUM(outstanding_principal) FROM loans WHERE status = 'active'), 0)
        AS outstanding_tzs
  )
SELECT
  a.pool_tzs,
  a.outstanding_tzs,
  a.pool_tzs + a.outstanding_tzs                              AS total_assets_tzs,
  c.member_capital                                            AS member_capital_tzs,
  e.retained_earnings                                         AS retained_earnings_tzs,
  j.pool_adjustments_tzs,
  c.member_capital + e.retained_earnings + j.pool_adjustments_tzs AS total_claims_tzs,
  (a.pool_tzs + a.outstanding_tzs)
    - (c.member_capital + e.retained_earnings + j.pool_adjustments_tzs) AS difference_tzs,
  (a.pool_tzs + a.outstanding_tzs)
    = (c.member_capital + e.retained_earnings + j.pool_adjustments_tzs) AS balanced
FROM assets a, capital c, earnings e, adjustments j;

-- Every member can see that the group's books balance. That is the same
-- transparency stance as the member directory (019) and the share-out (024), and
-- a reconciliation only the admins can see is worth much less.
GRANT SELECT ON v_pool_reconciliation TO authenticated;

-- ---------------------------------------------------------------------------
-- 028_loan_guarantors.sql
-- ---------------------------------------------------------------------------

-- 028_loan_guarantors.sql — co-signers who stand behind a loan.
--
-- The standard SACCOS risk control, and the last big one this app was missing. A
-- borrower nominates one or more guarantors; each pledges an amount of their own
-- savings and must ACCEPT before the loan can be approved. While the loan is live
-- the pledge is locked — a guarantor cannot withdraw money they have promised.
--
-- If the loan is written off, the admins may CALL the pledges instead of the group
-- absorbing the whole loss.
--
-- TWO DELIBERATE NON-CHANGES:
--
--   * A guarantee does NOT raise the loan ceiling. min(multiplier x contribution,
--     fraction x pool) stands. Letting guarantees lift the cap is a policy decision
--     for the group to vote on, not something to smuggle in with the mechanism.
--   * No new lock mechanism. member_withdrawable() (025) already computes what a
--     member may take out and already reports `locked_tzs` for a borrower's own
--     collateral; accepted pledges simply add to the same figure, so the member's
--     withdrawal screen explains itself with no UI change.
--
-- Requires 022 (loan_recoveries) and 025 (member_withdrawable).

-- --------------------------------------------------------------------------
-- 1. Schema
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS loan_guarantors (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_id       uuid NOT NULL REFERENCES loans(id) ON DELETE CASCADE,
  guarantor_id  uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  pledged_amount numeric(12,2) NOT NULL CHECK (pledged_amount > 0),
  status        text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'accepted', 'declined', 'released', 'called')),
  responded_at  timestamptz,
  called_amount numeric(12,2) NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (loan_id, guarantor_id)
);
CREATE INDEX IF NOT EXISTS loan_guarantors_guarantor_idx
  ON loan_guarantors (guarantor_id, status);

ALTER TABLE loan_guarantors ENABLE ROW LEVEL SECURITY;

-- Everyone sees who backs whom. Standing behind a loan is a public act in a group
-- this size — and a guarantor needs to see the request to accept it.
DROP POLICY IF EXISTS "Everyone reads guarantees" ON loan_guarantors;
CREATE POLICY "Everyone reads guarantees" ON loan_guarantors
  FOR SELECT USING (auth.uid() IS NOT NULL);

GRANT SELECT ON loan_guarantors TO authenticated;

-- --------------------------------------------------------------------------
-- 2. member_withdrawable — accepted pledges join the borrower's own collateral.
--
--    Same shape as 025; the only change is the extra `pledged` term. Redefined in
--    full rather than patched because the CTE has to compute both together.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION member_withdrawable(p_member_id uuid)
RETURNS TABLE (
  savings_tzs      numeric,
  outstanding_tzs  numeric,
  locked_tzs       numeric,
  pool_tzs         numeric,
  withdrawable_tzs numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH s AS (
    SELECT
        COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                   WHERE member_id = p_member_id
                     AND submission_type = 'savings_deposit'
                     AND status = 'approved'), 0)
      + COALESCE((SELECT SUM(amount_paid) FROM monthly_fees
                   WHERE member_id = p_member_id), 0)
      + COALESCE((SELECT SUM(delta) FROM savings_adjustments
                   WHERE target_member_id = p_member_id AND status = 'approved'), 0)
      - COALESCE((SELECT SUM(amount) FROM withdrawal_requests
                   WHERE member_id = p_member_id AND status IN ('pending', 'approved')), 0)
        AS savings,
      COALESCE((SELECT SUM(COALESCE(outstanding_principal, principal))
                  FROM loans WHERE member_id = p_member_id AND status = 'active'), 0)
        AS outstanding,
      -- Money promised to somebody else's loan is not this member's to withdraw.
      COALESCE((SELECT SUM(g.pledged_amount)
                  FROM loan_guarantors g
                  JOIN loans l ON l.id = g.loan_id
                 WHERE g.guarantor_id = p_member_id
                   AND g.status = 'accepted'
                   AND l.status IN ('pending', 'active')), 0)
        AS pledged,
      (SELECT pool_balance_tzs FROM v_group_pool) AS pool
  ),
  l AS (
    SELECT s.*,
      CASE WHEN s.outstanding > 0
           THEN ceil(s.outstanding / greatest(setting('contribution_multiplier'), 1))
           ELSE 0 END + s.pledged AS locked
    FROM s
  )
  SELECT
    l.savings,
    l.outstanding,
    l.locked,
    l.pool,
    greatest(least(l.savings - l.locked, l.pool), 0)
  FROM l;
$$;

-- --------------------------------------------------------------------------
-- 3. Nominating and responding.
--
--    A pledge is capped at what the guarantor could actually withdraw today: a
--    promise larger than their free savings is a promise they cannot keep.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION nominate_guarantor(
  p_loan_id uuid, p_guarantor_id uuid, p_amount numeric
)
RETURNS uuid AS $$
DECLARE
  v_id        uuid;
  v_loan      loans%ROWTYPE;
  v_free      numeric(14,2);
  v_borrower  text;
BEGIN
  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id;
  IF v_loan.id IS NULL THEN RAISE EXCEPTION 'Loan not found'; END IF;
  IF v_loan.member_id <> auth.uid() THEN
    RAISE EXCEPTION 'Only the borrower can nominate their guarantors';
  END IF;
  IF v_loan.status <> 'pending' THEN
    RAISE EXCEPTION 'Guarantors can only be added while the request is still pending';
  END IF;
  IF p_guarantor_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot guarantee your own loan';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Enter the amount they are guaranteeing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_guarantor_id AND is_active = true) THEN
    RAISE EXCEPTION 'That member is not active';
  END IF;

  SELECT withdrawable_tzs INTO v_free FROM member_withdrawable(p_guarantor_id);
  IF p_amount > v_free THEN
    RAISE EXCEPTION 'They can only guarantee up to % — the rest of their savings is already committed',
      v_free;
  END IF;

  INSERT INTO loan_guarantors (loan_id, guarantor_id, pledged_amount)
  VALUES (p_loan_id, p_guarantor_id, p_amount)
  RETURNING id INTO v_id;

  SELECT full_name INTO v_borrower FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (p_guarantor_id, 'guarantee_requested',
          'You have been asked to guarantee a loan',
          COALESCE(v_borrower, 'A member') || ' has asked you to guarantee ' ||
            p_amount || ' TZS of their loan.',
          jsonb_build_object('loan_id', p_loan_id, 'guarantee_id', v_id));

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'nominate_guarantor', 'loan', p_loan_id,
          jsonb_build_object('guarantor_id', p_guarantor_id, 'amount', p_amount));

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION respond_to_guarantee(p_guarantee_id uuid, p_accept boolean)
RETURNS void AS $$
DECLARE
  v_g        loan_guarantors%ROWTYPE;
  v_free     numeric(14,2);
  v_borrower uuid;
  v_name     text;
BEGIN
  SELECT * INTO v_g FROM loan_guarantors WHERE id = p_guarantee_id FOR UPDATE;
  IF v_g.id IS NULL              THEN RAISE EXCEPTION 'Guarantee not found';        END IF;
  IF v_g.guarantor_id <> auth.uid() THEN RAISE EXCEPTION 'Not your guarantee';      END IF;
  IF v_g.status <> 'pending'     THEN RAISE EXCEPTION 'You have already responded'; END IF;

  IF p_accept THEN
    -- Re-check at acceptance: their balance may have moved since the nomination.
    SELECT withdrawable_tzs INTO v_free FROM member_withdrawable(auth.uid());
    IF v_g.pledged_amount > v_free THEN
      RAISE EXCEPTION 'You only have % free to guarantee right now', v_free;
    END IF;
  END IF;

  UPDATE loan_guarantors
     SET status = CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END,
         responded_at = now()
   WHERE id = p_guarantee_id;

  SELECT member_id INTO v_borrower FROM loans WHERE id = v_g.loan_id;
  SELECT full_name INTO v_name FROM profiles WHERE id = auth.uid();

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_borrower,
          CASE WHEN p_accept THEN 'guarantee_accepted' ELSE 'guarantee_declined' END,
          CASE WHEN p_accept THEN 'Guarantee accepted' ELSE 'Guarantee declined' END,
          COALESCE(v_name, 'A member') ||
            CASE WHEN p_accept THEN ' is guaranteeing your loan.'
                 ELSE ' declined to guarantee your loan.' END,
          jsonb_build_object('loan_id', v_g.loan_id));

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), CASE WHEN p_accept THEN 'accept_guarantee' ELSE 'decline_guarantee' END,
          'loan', v_g.loan_id,
          jsonb_build_object('guarantee_id', p_guarantee_id, 'amount', v_g.pledged_amount));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- The borrower can withdraw a nomination that has not been answered yet.
CREATE OR REPLACE FUNCTION cancel_guarantee(p_guarantee_id uuid)
RETURNS void AS $$
DECLARE
  v_g        loan_guarantors%ROWTYPE;
  v_borrower uuid;
BEGIN
  SELECT * INTO v_g FROM loan_guarantors WHERE id = p_guarantee_id;
  IF v_g.id IS NULL THEN RETURN; END IF;

  SELECT member_id INTO v_borrower FROM loans WHERE id = v_g.loan_id;
  IF v_borrower <> auth.uid() AND NOT is_admin() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF v_g.status <> 'pending' THEN
    RAISE EXCEPTION 'Only an unanswered nomination can be withdrawn';
  END IF;

  DELETE FROM loan_guarantors WHERE id = p_guarantee_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 4. approve_loan — refuse while a nomination is unanswered.
--
--    Everything else is the 020 version unchanged. A loan with no guarantors at
--    all is still fine: guarantees are a tool the group can use, not a mandate.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_loan(p_loan_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_loan              loans%ROWTYPE;
  v_int               numeric(12,2);
  v_pool              numeric(14,2);
  v_contribution      numeric(14,2);
  v_required          int;
  v_approvals         int;
  v_final_proof       text;
  v_other_admin_loans int;
  v_total_admins      int;
  v_unanswered        int;
  v_fraction          numeric := setting('pool_loan_fraction');
  v_multiplier        numeric := setting('contribution_multiplier');
  v_rate              numeric := setting('loan_interest_rate');
  v_months            int     := setting('default_loan_months')::int;
  v_n                 int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL             THEN RAISE EXCEPTION 'Loan not found';      END IF;
  IF v_loan.status <> 'pending'    THEN RAISE EXCEPTION 'Loan is not pending'; END IF;
  IF v_loan.member_id = auth.uid() THEN RAISE EXCEPTION 'Cannot approve your own loan'; END IF;

  -- Approving while a guarantor has not answered would bind them to a decision
  -- they never made.
  SELECT count(*) INTO v_unanswered
    FROM loan_guarantors WHERE loan_id = p_loan_id AND status = 'pending';
  IF v_unanswered > 0 THEN
    RAISE EXCEPTION '% nominated guarantor(s) have not responded yet', v_unanswered;
  END IF;

  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;
  IF v_loan.principal > floor(v_fraction * COALESCE(v_pool, 0)) THEN
    RAISE EXCEPTION 'Loan exceeds % of the group pool (max %).',
      round(v_fraction * 100) || '%', floor(v_fraction * COALESCE(v_pool, 0));
  END IF;

  SELECT
      COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                WHERE member_id = v_loan.member_id
                  AND submission_type = 'savings_deposit'
                  AND status = 'approved'), 0)
    + COALESCE((SELECT SUM(amount) FROM monthly_fees
                WHERE member_id = v_loan.member_id AND status = 'paid'), 0)
  INTO v_contribution;
  IF v_loan.principal > floor(v_multiplier * v_contribution) THEN
    RAISE EXCEPTION 'Loan exceeds %x member contribution (max %).',
      v_multiplier, floor(v_multiplier * v_contribution);
  END IF;

  BEGIN
    INSERT INTO loan_approvals (loan_id, admin_id, proof_url)
    VALUES (p_loan_id, auth.uid(), p_proof_url);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this loan';
  END;

  v_required := required_approvals();
  SELECT count(*) INTO v_approvals FROM loan_approvals WHERE loan_id = p_loan_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_loan', 'loan', p_loan_id,
            jsonb_build_object(
              'member_id', v_loan.member_id,
              'principal', v_loan.principal,
              'approvals', v_approvals,
              'required',  v_required
            ));
    RETURN;
  END IF;

  IF (SELECT role FROM profiles WHERE id = v_loan.member_id) = 'admin' THEN
    SELECT count(*) INTO v_total_admins
      FROM profiles WHERE role = 'admin' AND is_active = true;
    SELECT count(*) INTO v_other_admin_loans
      FROM loans
      WHERE status = 'active'
        AND member_id IN (SELECT id FROM profiles WHERE role = 'admin' AND is_active = true)
        AND member_id <> v_loan.member_id;
    IF v_other_admin_loans >= v_total_admins - 1 THEN
      RAISE EXCEPTION 'Not all admins may hold loans simultaneously; one admin must remain loan-free.';
    END IF;
  END IF;

  SELECT proof_url INTO v_final_proof
  FROM loan_approvals WHERE loan_id = p_loan_id
  ORDER BY approved_at ASC LIMIT 1;

  v_int := round(v_loan.principal * v_rate);

  UPDATE loans
    SET status = 'active',
        approved_at = now(),
        approved_by = auth.uid(),
        disbursed_at = now(),
        disbursement_proof_url = v_final_proof,
        outstanding_principal = v_loan.principal,
        interest_rate = v_rate
    WHERE id = p_loan_id;

  FOR v_n IN 1..v_months LOOP
    INSERT INTO loan_installments
      (loan_id, installment_number, due_date, principal_due, interest_due, penalty_rate)
    VALUES (
      p_loan_id,
      v_n,
      (today_eat() + (v_n || ' month')::interval)::date,
      CASE WHEN v_n = v_months THEN v_loan.principal ELSE 0 END,
      v_int,
      setting('penalty_rate')
    );
  END LOOP;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_loan', 'loan', p_loan_id,
          jsonb_build_object(
            'member_id',     v_loan.member_id,
            'principal',     v_loan.principal,
            'approvals',     v_approvals,
            'interest_rate', v_rate,
            'months',        v_months,
            'guarantors',    (SELECT count(*) FROM loan_guarantors
                               WHERE loan_id = p_loan_id AND status = 'accepted')
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- --------------------------------------------------------------------------
-- 5. Releasing and calling.
--
--    Release is automatic: the moment a loan stops being a liability, the pledge
--    stops locking anyone's savings. A trigger does it so no code path can forget.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION release_guarantees_on_loan_close()
RETURNS trigger AS $$
BEGIN
  IF NEW.status IN ('closed', 'rejected') AND OLD.status <> NEW.status THEN
    UPDATE loan_guarantors
       SET status = 'released'
     WHERE loan_id = NEW.id AND status IN ('pending', 'accepted');
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS on_loan_close_release_guarantees ON loans;
CREATE TRIGGER on_loan_close_release_guarantees
  AFTER UPDATE OF status ON loans
  FOR EACH ROW EXECUTE FUNCTION release_guarantees_on_loan_close();

-- Calling the pledges after a write-off: 2-of-N, and it reuses 022's machinery
-- exactly — a negative savings_adjustments row per guarantor, each offset by a
-- loan_recoveries row so no cash moves and the pool stays correct.
--
-- Called amounts are capped at the shortfall and shared pro-rata across the
-- accepted pledges, so no guarantor pays more than their share of what was lost.
CREATE OR REPLACE FUNCTION call_guarantees(p_loan_id uuid, p_reason text)
RETURNS numeric AS $$
DECLARE
  v_loan      loans%ROWTYPE;
  v_shortfall numeric(14,2);
  v_pledged   numeric(14,2);
  v_total     numeric(14,2) := 0;
  g           record;
  v_share     numeric(14,2);
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required to call a guarantee';
  END IF;

  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL THEN RAISE EXCEPTION 'Loan not found'; END IF;
  IF v_loan.status <> 'written_off' THEN
    RAISE EXCEPTION 'Guarantees are only called on a loan that has been written off';
  END IF;
  IF v_loan.member_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot call the guarantees on your own loan';
  END IF;

  -- What the group actually lost: the write-off entry booked in 022.
  SELECT COALESCE(-SUM(amount), 0) INTO v_shortfall
    FROM earnings_ledger
   WHERE kind = 'write_off' AND source_type = 'loan' AND source_id = p_loan_id;
  IF v_shortfall <= 0 THEN RAISE EXCEPTION 'This loan recorded no loss to recover'; END IF;

  SELECT COALESCE(SUM(pledged_amount), 0) INTO v_pledged
    FROM loan_guarantors WHERE loan_id = p_loan_id AND status = 'accepted';
  IF v_pledged <= 0 THEN RAISE EXCEPTION 'This loan has no accepted guarantees'; END IF;

  FOR g IN
    SELECT * FROM loan_guarantors WHERE loan_id = p_loan_id AND status = 'accepted'
  LOOP
    -- Never more than they promised, never more than their share of the loss.
    v_share := least(g.pledged_amount, round(v_shortfall * g.pledged_amount / v_pledged));
    IF v_share > 0 THEN
      INSERT INTO savings_adjustments
        (target_member_id, requested_by, delta, reason, status, applied_at)
      VALUES (g.guarantor_id, auth.uid(), -v_share,
              'Guarantee called: ' || p_reason, 'approved', now());

      INSERT INTO loan_recoveries (loan_id, member_id, amount)
      VALUES (p_loan_id, g.guarantor_id, v_share);

      -- The loss is partly recovered, so reverse that much of the write-off.
      INSERT INTO earnings_ledger (member_id, kind, amount, source_type, source_id)
      VALUES (g.guarantor_id, 'write_off', v_share, 'loan', p_loan_id);

      INSERT INTO notifications (recipient_id, kind, title, body, data)
      VALUES (g.guarantor_id, 'guarantee_called', 'Your guarantee has been called',
              v_share || ' TZS was taken from your savings to cover the loan you guaranteed.',
              jsonb_build_object('loan_id', p_loan_id));

      v_total := v_total + v_share;
    END IF;

    UPDATE loan_guarantors
       SET status = 'called', called_amount = v_share
     WHERE id = g.id;
  END LOOP;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'call_guarantees', 'loan', p_loan_id,
          jsonb_build_object('shortfall', v_shortfall, 'recovered', v_total, 'reason', p_reason));

  RETURN v_total;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 029_reports.sql
-- ---------------------------------------------------------------------------

-- 029_reports.sql — the numbers a group reads out at its annual meeting.
--
-- Members could already download their own statement (Phase 4), but the GROUP had
-- no accounts: no income statement, no balance sheet, nothing to project on a wall
-- at an AGM and say "this is what we made and this is what we hold".
--
-- Almost no new data is needed. 021's earnings_ledger records every shilling of
-- income with a date, and 023's v_member_capital_events reconstructs any member's
-- capital at any point in time — both were built for the share-out and turn out to
-- be exactly what a set of accounts needs. This migration is mostly presentation.
--
-- The balance sheet reuses the SAME identity as v_pool_reconciliation (027), so the
-- report and the books-balance check can never tell the group different stories.
--
-- Requires 021, 023, 027.

-- --------------------------------------------------------------------------
-- 1. Income statement — what the group earned over a period.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION group_income_statement(p_from date, p_to date)
RETURNS TABLE (
  interest_tzs   numeric,
  penalty_tzs    numeric,
  write_off_tzs  numeric,
  net_tzs        numeric,
  loans_issued   bigint,
  loans_issued_tzs numeric,
  fees_collected_tzs numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    COALESCE((SELECT SUM(amount) FROM earnings_ledger
               WHERE kind = 'interest' AND occurred_at::date BETWEEN p_from AND p_to), 0),
    COALESCE((SELECT SUM(amount) FROM earnings_ledger
               WHERE kind = 'penalty' AND occurred_at::date BETWEEN p_from AND p_to), 0),
    COALESCE((SELECT SUM(amount) FROM earnings_ledger
               WHERE kind = 'write_off' AND occurred_at::date BETWEEN p_from AND p_to), 0),
    COALESCE((SELECT SUM(amount) FROM earnings_ledger
               WHERE occurred_at::date BETWEEN p_from AND p_to), 0),
    -- Activity, not income: how much lending the group actually did.
    COALESCE((SELECT count(*) FROM loans
               WHERE approved_at::date BETWEEN p_from AND p_to), 0),
    COALESCE((SELECT SUM(principal) FROM loans
               WHERE approved_at::date BETWEEN p_from AND p_to), 0),
    -- Fee base is members' own capital, never income — reported separately so
    -- nobody mistakes a healthy fee month for profit.
    COALESCE((SELECT SUM(ps.amount_claimed) FROM payment_submissions ps
               WHERE ps.submission_type = 'monthly_fee' AND ps.status = 'approved'
                 AND COALESCE(ps.reviewed_at, ps.submitted_at)::date BETWEEN p_from AND p_to), 0);
$$;

GRANT EXECUTE ON FUNCTION group_income_statement(date, date) TO authenticated;

-- --------------------------------------------------------------------------
-- 2. Balance sheet — what the group holds, and whose it is.
--
--    Same identity as v_pool_reconciliation (027): assets = claims. Reported
--    as-at a date so a closed cycle can be re-read exactly as it stood.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION group_balance_sheet(p_as_of date DEFAULT NULL)
RETURNS TABLE (
  as_of              date,
  pool_tzs           numeric,
  outstanding_tzs    numeric,
  total_assets_tzs   numeric,
  member_capital_tzs numeric,
  retained_earnings_tzs numeric,
  distributions_paid_tzs numeric,
  total_claims_tzs   numeric,
  difference_tzs     numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH d AS (SELECT COALESCE(p_as_of, today_eat()) AS as_of),
  cap AS (
    SELECT COALESCE(SUM(e.amount), 0) AS member_capital
    FROM v_member_capital_events e, d
    WHERE e.occurred_at::date <= d.as_of
  ),
  earn AS (
    SELECT COALESCE(SUM(el.amount), 0) AS retained
    FROM earnings_ledger el, d
    WHERE el.occurred_at::date <= d.as_of
  ),
  dist AS (
    SELECT COALESCE(SUM(x.earnings_tzs), 0) AS paid
    FROM distributions x, d
    WHERE x.status = 'paid' AND x.paid_at::date <= d.as_of
  ),
  adj AS (
    SELECT COALESCE(SUM(p.delta), 0) AS pool_adj
    FROM pool_adjustments p, d
    WHERE p.status = 'approved' AND COALESCE(p.applied_at, p.created_at)::date <= d.as_of
  ),
  assets AS (
    SELECT
      (SELECT pool_balance_tzs FROM v_group_pool) AS pool,
      COALESCE((SELECT SUM(outstanding_principal) FROM loans WHERE status = 'active'), 0)
        AS outstanding
  )
  SELECT
    d.as_of,
    a.pool,
    a.outstanding,
    a.pool + a.outstanding,
    c.member_capital,
    e.retained,
    x.paid,
    c.member_capital + e.retained - x.paid + j.pool_adj,
    (a.pool + a.outstanding) - (c.member_capital + e.retained - x.paid + j.pool_adj)
  FROM d, assets a, cap c, earn e, dist x, adj j;
$$;

GRANT EXECUTE ON FUNCTION group_balance_sheet(date) TO authenticated;

-- --------------------------------------------------------------------------
-- 3. Per-member ledger — every movement in one member's capital, with a running
--    balance. This is what settles an argument about somebody's savings.
--
--    security_invoker is not available on a function, so this checks explicitly:
--    a member may read their own ledger, an admin may read anyone's.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION member_ledger(
  p_member uuid, p_from date DEFAULT NULL, p_to date DEFAULT NULL
)
RETURNS TABLE (
  occurred_at timestamptz,
  kind        text,
  amount      numeric,
  balance     numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_member <> auth.uid() AND NOT is_admin() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  RETURN QUERY
  SELECT
    e.occurred_at,
    e.kind,
    e.amount,
    -- Running balance over the whole history, then filtered — so a ledger for a
    -- single month still opens at the right number rather than at zero.
    SUM(e.amount) OVER (ORDER BY e.occurred_at, e.kind
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
  FROM v_member_capital_events e
  WHERE e.member_id = p_member
    AND (p_from IS NULL OR e.occurred_at::date >= p_from)
    AND (p_to   IS NULL OR e.occurred_at::date <= p_to)
  ORDER BY e.occurred_at, e.kind;
END;
$$;

GRANT EXECUTE ON FUNCTION member_ledger(uuid, date, date) TO authenticated;

-- --------------------------------------------------------------------------
-- 4. Member summary for the AGM — one row per member: capital, what they still
--    owe, and what they earned from the last closed cycle.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION group_member_report(p_as_of date DEFAULT NULL)
RETURNS TABLE (
  member_id      uuid,
  full_name      text,
  role           text,
  capital_tzs    numeric,
  outstanding_tzs numeric,
  fees_paid_tzs  numeric,
  penalties_tzs  numeric,
  last_payout_tzs numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH d AS (SELECT COALESCE(p_as_of, today_eat()) AS as_of)
  SELECT
    p.id,
    p.full_name,
    p.role,
    COALESCE((SELECT SUM(e.amount) FROM v_member_capital_events e, d
               WHERE e.member_id = p.id AND e.occurred_at::date <= d.as_of), 0),
    COALESCE((SELECT SUM(COALESCE(l.outstanding_principal, l.principal))
               FROM loans l WHERE l.member_id = p.id AND l.status = 'active'), 0),
    COALESCE((SELECT SUM(f.amount_paid) FROM monthly_fees f WHERE f.member_id = p.id), 0),
    -- Penalties this member has paid: a fine, not a contribution, and the one
    -- number that shows who is carrying the group and who is costing it.
    COALESCE((SELECT SUM(el.amount) FROM earnings_ledger el
               WHERE el.member_id = p.id AND el.kind = 'penalty'), 0),
    COALESCE((SELECT x.total_payout_tzs FROM distributions x
               JOIN cycles c ON c.id = x.cycle_id
              WHERE x.member_id = p.id
              ORDER BY c.end_date DESC LIMIT 1), 0)
  FROM profiles p, d
  WHERE p.is_active = true
  ORDER BY p.full_name;
$$;

GRANT EXECUTE ON FUNCTION group_member_report(date) TO authenticated;

-- ---------------------------------------------------------------------------
-- 030_meetings_and_social_fund.sql
-- ---------------------------------------------------------------------------

-- 030_meetings_and_social_fund.sql — the two structures every VICOBA has that
-- this app did not model at all.
--
-- 1. MEETINGS AND ATTENDANCE. The group meets monthly; that is where loans get
--    agreed and rules get voted on. Attendance fines are a normal revenue line and
--    the main thing that keeps a meeting quorate.
--
--    Fines are DEDUCTED, not invoiced. A fine writes a negative savings_adjustments
--    row plus a positive earnings_ledger row, so it flows straight into the
--    member's balance, the transparency directory, the pool and the cycle
--    share-out with no new plumbing — and approve_submission is not touched a
--    fourth time. Fine amounts are group_settings keys, so they change by the same
--    2-of-N vote as every other rule.
--
-- 2. SOCIAL FUND (bima ya jamii). A separate pot for funerals and medical
--    emergencies. Deliberately OUTSIDE v_group_pool: it is welfare money, not
--    loanable capital, and folding it in would silently raise every member's loan
--    ceiling (the cap is a fraction of the pool). Kept separate, it also cannot be
--    lent out by accident.
--
-- Requires 020 (settings), 021 (earnings_ledger).

-- --------------------------------------------------------------------------
-- 1. Fine amounts as group rules
-- --------------------------------------------------------------------------

INSERT INTO group_settings (key, value, min_value, max_value, label) VALUES
  ('attendance_fine_late',   1000, 0, 100000, 'Fine for arriving late'),
  ('attendance_fine_absent', 2000, 0, 100000, 'Fine for missing a meeting')
ON CONFLICT (key) DO NOTHING;

-- --------------------------------------------------------------------------
-- 2. Meetings and the register
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS meetings (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  held_on    date NOT NULL,
  title      text NOT NULL,
  minutes    text,
  cycle_id   uuid REFERENCES cycles(id) ON DELETE SET NULL,
  -- Fines only bite once. Recording the register is reversible; applying the
  -- fines is not, so it is a separate, explicit step.
  fines_applied_at timestamptz,
  created_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS meetings_held_on_idx ON meetings (held_on DESC);

CREATE TABLE IF NOT EXISTS meeting_attendance (
  meeting_id uuid NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  member_id  uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  status     text NOT NULL DEFAULT 'present'
               CHECK (status IN ('present', 'late', 'excused', 'absent')),
  fine_tzs   numeric(12,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (meeting_id, member_id)
);

ALTER TABLE meetings           ENABLE ROW LEVEL SECURITY;
ALTER TABLE meeting_attendance ENABLE ROW LEVEL SECURITY;

-- Minutes and the register are the group's record; everyone reads them.
DROP POLICY IF EXISTS "Everyone reads meetings" ON meetings;
CREATE POLICY "Everyone reads meetings" ON meetings
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Everyone reads attendance" ON meeting_attendance;
CREATE POLICY "Everyone reads attendance" ON meeting_attendance
  FOR SELECT USING (auth.uid() IS NOT NULL);

GRANT SELECT ON meetings, meeting_attendance TO authenticated;

-- --------------------------------------------------------------------------
-- 3. Recording a meeting
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION record_meeting(
  p_held_on date, p_title text, p_minutes text DEFAULT NULL
)
RETURNS uuid AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(trim(p_title), '') = '' THEN RAISE EXCEPTION 'Give the meeting a title'; END IF;
  IF p_held_on > today_eat() THEN RAISE EXCEPTION 'A meeting cannot be recorded in the future'; END IF;

  INSERT INTO meetings (held_on, title, minutes, created_by, cycle_id)
  VALUES (p_held_on, trim(p_title), NULLIF(trim(p_minutes), ''), auth.uid(),
          (SELECT id FROM cycles WHERE status = 'open' LIMIT 1))
  RETURNING id INTO v_id;

  -- Everyone starts present; the admin marks the exceptions. In a 15-member group
  -- that is far less tapping than the other way round.
  INSERT INTO meeting_attendance (meeting_id, member_id, status)
  SELECT v_id, p.id, 'present' FROM profiles p WHERE p.is_active = true;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'record_meeting', 'meeting', v_id,
          jsonb_build_object('held_on', p_held_on, 'title', p_title));

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION set_attendance(
  p_meeting_id uuid, p_member_id uuid, p_status text
)
RETURNS void AS $$
DECLARE
  v_applied timestamptz;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_status NOT IN ('present', 'late', 'excused', 'absent') THEN
    RAISE EXCEPTION 'Unknown attendance status: %', p_status;
  END IF;

  SELECT fines_applied_at INTO v_applied FROM meetings WHERE id = p_meeting_id;
  IF v_applied IS NOT NULL THEN
    RAISE EXCEPTION 'The fines for this meeting have already been applied';
  END IF;

  INSERT INTO meeting_attendance (meeting_id, member_id, status)
  VALUES (p_meeting_id, p_member_id, p_status)
  ON CONFLICT (meeting_id, member_id) DO UPDATE SET status = EXCLUDED.status;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION update_meeting_minutes(p_meeting_id uuid, p_minutes text)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE meetings SET minutes = NULLIF(trim(p_minutes), '') WHERE id = p_meeting_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 4. Applying the fines — once, and irreversibly.
--
--    Each fine is a negative savings adjustment (the member's balance falls) plus
--    a positive earnings entry (the group's income rises). That is the same pair
--    022 uses for a loan recovery, and it means the fine reaches the pool, the
--    directory and the share-out with no code that knows what a fine is.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION apply_attendance_fines(p_meeting_id uuid)
RETURNS numeric AS $$
DECLARE
  v_meeting meetings%ROWTYPE;
  v_late    numeric := setting('attendance_fine_late');
  v_absent  numeric := setting('attendance_fine_absent');
  v_total   numeric := 0;
  r         record;
  v_fine    numeric;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF v_meeting.id IS NULL THEN RAISE EXCEPTION 'Meeting not found'; END IF;
  IF v_meeting.fines_applied_at IS NOT NULL THEN
    RAISE EXCEPTION 'The fines for this meeting have already been applied';
  END IF;

  FOR r IN
    SELECT * FROM meeting_attendance WHERE meeting_id = p_meeting_id
  LOOP
    -- 'excused' is the whole point of having four statuses rather than two: a
    -- member who sent word is not fined.
    v_fine := CASE r.status
                WHEN 'late'   THEN v_late
                WHEN 'absent' THEN v_absent
                ELSE 0
              END;

    IF v_fine > 0 THEN
      INSERT INTO savings_adjustments
        (target_member_id, requested_by, delta, reason, status, applied_at)
      VALUES (r.member_id, auth.uid(), -v_fine,
              'Attendance fine: ' || v_meeting.title || ' (' || r.status || ')',
              'approved', now());

      INSERT INTO earnings_ledger (member_id, kind, amount, source_type, source_id)
      VALUES (r.member_id, 'penalty', v_fine, 'meeting', p_meeting_id);

      UPDATE meeting_attendance SET fine_tzs = v_fine
       WHERE meeting_id = p_meeting_id AND member_id = r.member_id;

      INSERT INTO notifications (recipient_id, kind, title, body, data)
      VALUES (r.member_id, 'attendance_fine', 'Attendance fine',
              v_fine || ' TZS was deducted from your savings for ' ||
                CASE r.status WHEN 'late' THEN 'arriving late to ' ELSE 'missing ' END ||
                v_meeting.title || '.',
              jsonb_build_object('meeting_id', p_meeting_id));

      v_total := v_total + v_fine;
    END IF;
  END LOOP;

  UPDATE meetings SET fines_applied_at = now() WHERE id = p_meeting_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'apply_attendance_fines', 'meeting', p_meeting_id,
          jsonb_build_object('total', v_total, 'late', v_late, 'absent', v_absent));

  RETURN v_total;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. v_group_pool — a fine moves ownership, not cash.
--
--    NO CASH MOVES WHEN A FINE IS LEVIED. The money is already sitting in the
--    pool as the member's savings; the fine only changes whose it is — the
--    member's capital falls and the group's earnings rise by the same amount.
--
--    But the negative savings_adjustments row a fine writes is, on its own, read
--    by v_group_pool as cash leaving. Without an offsetting term the pool would
--    drop by every fine ever levied while retained earnings rose by the same
--    amount, so assets and claims would drift apart by the total fines collected
--    and v_pool_reconciliation would (correctly) report the books as broken.
--
--    Same fix as loan_recoveries in 022, for the same reason.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_group_pool AS
SELECT
    (SELECT COALESCE(SUM(amount_claimed), 0)
       FROM payment_submissions
       WHERE submission_type = 'savings_deposit' AND status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM savings_adjustments WHERE status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM pool_adjustments    WHERE status = 'approved')
  + (SELECT COALESCE(SUM(amount), 0)
       FROM loan_recoveries)
  -- Offsets the negative savings adjustment each fine writes.
  + (SELECT COALESCE(SUM(fine_tzs), 0)
       FROM meeting_attendance)
  + (SELECT COALESCE(SUM(amount_paid), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM monthly_fees)
  + (SELECT COALESCE(SUM(interest_paid), 0)
           + COALESCE(SUM(principal_paid), 0)
           + COALESCE(SUM(penalty_collected), 0)
       FROM loan_installments)
  - (SELECT COALESCE(SUM(principal), 0)
       FROM loans             WHERE status IN ('active', 'closed', 'written_off'))
  - (SELECT COALESCE(SUM(earnings_tzs), 0)
       FROM distributions     WHERE status = 'paid')
  AS pool_balance_tzs;

-- --------------------------------------------------------------------------
-- 6. Social fund — a separate pot.
--
--    Contributions and grants are tracked here and NOWHERE in v_group_pool. It is
--    welfare money: not lendable, not part of anyone's loan ceiling, and not
--    shared out at the end of a cycle.
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS social_fund_entries (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id   uuid REFERENCES profiles(id) ON DELETE SET NULL,
  kind        text NOT NULL CHECK (kind IN ('contribution', 'grant')),
  amount      numeric(12,2) NOT NULL CHECK (amount > 0),
  reason      text NOT NULL,
  recorded_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
  proof_url   text,
  occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS social_fund_entries_kind_idx ON social_fund_entries (kind, occurred_at DESC);

CREATE TABLE IF NOT EXISTS social_fund_grant_requests (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  amount       numeric(12,2) NOT NULL CHECK (amount > 0),
  reason       text NOT NULL,
  status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'rejected')),
  requested_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  applied_at   timestamptz
);

CREATE TABLE IF NOT EXISTS social_fund_grant_approvals (
  request_id  uuid NOT NULL REFERENCES social_fund_grant_requests(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, admin_id)
);

ALTER TABLE social_fund_entries         ENABLE ROW LEVEL SECURITY;
ALTER TABLE social_fund_grant_requests  ENABLE ROW LEVEL SECURITY;
ALTER TABLE social_fund_grant_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Everyone reads social fund" ON social_fund_entries;
CREATE POLICY "Everyone reads social fund" ON social_fund_entries
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Everyone reads grant requests" ON social_fund_grant_requests;
CREATE POLICY "Everyone reads grant requests" ON social_fund_grant_requests
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Admins read grant approvals" ON social_fund_grant_approvals;
CREATE POLICY "Admins read grant approvals" ON social_fund_grant_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON social_fund_entries, social_fund_grant_requests,
                social_fund_grant_approvals TO authenticated;

CREATE OR REPLACE VIEW v_social_fund AS
SELECT
  COALESCE(SUM(amount) FILTER (WHERE kind = 'contribution'), 0) AS contributed_tzs,
  COALESCE(SUM(amount) FILTER (WHERE kind = 'grant'), 0)        AS granted_tzs,
  COALESCE(SUM(amount) FILTER (WHERE kind = 'contribution'), 0)
    - COALESCE(SUM(amount) FILTER (WHERE kind = 'grant'), 0)    AS balance_tzs
FROM social_fund_entries;

GRANT SELECT ON v_social_fund TO authenticated;

CREATE OR REPLACE FUNCTION record_social_contribution(
  p_member_id uuid, p_amount numeric, p_reason text, p_proof_url text DEFAULT NULL
)
RETURNS uuid AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Enter an amount'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN RAISE EXCEPTION 'A reason is required'; END IF;

  INSERT INTO social_fund_entries (member_id, kind, amount, reason, recorded_by, proof_url)
  VALUES (p_member_id, 'contribution', p_amount, trim(p_reason), auth.uid(), p_proof_url)
  RETURNING id INTO v_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'social_contribution', 'social_fund', v_id,
          jsonb_build_object('member_id', p_member_id, 'amount', p_amount));

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Paying out of the social fund is 2-of-N like every other outflow.
CREATE OR REPLACE FUNCTION request_social_grant(
  p_member_id uuid, p_amount numeric, p_reason text
)
RETURNS uuid AS $$
DECLARE
  v_id       uuid;
  v_balance  numeric;
  v_others   int;
  v_name     text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Enter an amount'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN RAISE EXCEPTION 'A reason is required'; END IF;

  SELECT balance_tzs INTO v_balance FROM v_social_fund;
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'The social fund holds only %', v_balance;
  END IF;

  INSERT INTO social_fund_grant_requests (member_id, amount, reason, requested_by)
  VALUES (p_member_id, p_amount, trim(p_reason), auth.uid())
  RETURNING id INTO v_id;

  SELECT full_name INTO v_name FROM profiles WHERE id = p_member_id;
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'social_grant_requested', 'Social fund grant proposed',
         p_amount || ' TZS for ' || COALESCE(v_name, 'a member') || ': ' || p_reason,
         jsonb_build_object('request_id', v_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_others
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  IF least(2, v_others) = 0 THEN
    PERFORM execute_social_grant(v_id);
  END IF;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION execute_social_grant(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_req     social_fund_grant_requests%ROWTYPE;
  v_balance numeric;
BEGIN
  SELECT * INTO v_req FROM social_fund_grant_requests WHERE id = p_request_id FOR UPDATE;
  IF v_req.id IS NULL          THEN RAISE EXCEPTION 'Grant request not found'; END IF;
  IF v_req.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';       END IF;

  SELECT balance_tzs INTO v_balance FROM v_social_fund;
  IF v_req.amount > v_balance THEN
    RAISE EXCEPTION 'The social fund holds only %', v_balance;
  END IF;

  INSERT INTO social_fund_entries (member_id, kind, amount, reason, recorded_by)
  VALUES (v_req.member_id, 'grant', v_req.amount, v_req.reason, auth.uid());

  UPDATE social_fund_grant_requests
     SET status = 'approved', applied_at = now() WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'social_grant', 'social_fund', p_request_id,
          jsonb_build_object('member_id', v_req.member_id, 'amount', v_req.amount));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_req.member_id, 'social_grant_approved', 'Social fund grant approved',
          v_req.amount || ' TZS has been granted to you from the social fund.',
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION approve_social_grant(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_req       social_fund_grant_requests%ROWTYPE;
  v_approvals int;
  v_others    int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_req FROM social_fund_grant_requests WHERE id = p_request_id FOR UPDATE;
  IF v_req.id IS NULL          THEN RAISE EXCEPTION 'Grant request not found'; END IF;
  IF v_req.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';       END IF;
  IF v_req.requested_by = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;

  BEGIN
    INSERT INTO social_fund_grant_approvals (request_id, admin_id)
    VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this grant';
  END;

  SELECT COALESCE(count(*), 0) INTO v_others
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_req.requested_by;
  SELECT count(*) INTO v_approvals
    FROM social_fund_grant_approvals WHERE request_id = p_request_id;

  IF v_approvals < least(2, v_others) THEN RETURN; END IF;

  PERFORM execute_social_grant(p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION reject_social_grant(p_request_id uuid)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE social_fund_grant_requests SET status = 'rejected'
   WHERE id = p_request_id AND status = 'pending';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 031_loan_multiplier_5x.sql
-- ---------------------------------------------------------------------------

-- 031_loan_multiplier_5x.sql — the loan ceiling moves from 3x savings to 5x.
--
-- `contribution_multiplier` has been a group_settings row since 020, so this is a
-- value change, not a logic change: every RPC and view already reads setting().
-- It is done as a migration rather than a 2-of-N vote because it is the rule the
-- group agreed to run on, and a fresh project must stand up with 5x too — the seed
-- in 020 is `ON CONFLICT DO NOTHING`, so an existing database keeps 3 until this
-- UPDATE runs.
--
-- What actually changes, and what does not:
--   * The contribution ceiling on a NEW request rises to floor(5 x contribution).
--     The 25% pool cap is untouched, and the effective max is still the LOWER of
--     the two — for most members the pool side will now be what binds.
--   * Loans already approved are not restated. The cap gates request/approval
--     only; nothing recomputes an existing principal.
--   * The withdrawal collateral guard (025) locks `outstanding / multiplier`, so a
--     borrower's locked savings FALL. A 90,000 outstanding locked 30,000 at 3x and
--     locks 18,000 at 5x. That is the same rule, not a loosened one: it still
--     mirrors the ceiling a loan of that size was approved under.
--
-- Requires 020.

UPDATE group_settings
   SET value = 5, updated_at = now()
 WHERE key = 'contribution_multiplier';

-- The COALESCE fallback in setting() has to move with the row, otherwise a
-- database that somehow lost the row would silently revert to 3x.
CREATE OR REPLACE FUNCTION setting(p_key text)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT value FROM group_settings WHERE key = p_key),
    CASE p_key
      WHEN 'monthly_fee_amount'     THEN 10000
      WHEN 'loan_interest_rate'     THEN 0.05
      WHEN 'penalty_rate'           THEN 0.05
      WHEN 'pool_loan_fraction'     THEN 0.25
      WHEN 'contribution_multiplier' THEN 5
      WHEN 'default_loan_months'    THEN 3
      ELSE 0
    END
  );
$$;

GRANT EXECUTE ON FUNCTION setting(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 032_notification_dispatch.sql
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- 033_swahili_messages.sql
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- 034_admin_mandate_lockdown.sql
-- ---------------------------------------------------------------------------

-- 034_admin_mandate_lockdown.sql — admins hold the mandate; members only read.
--
-- Two halves, and the second is the one that matters.
--
-- HALF ONE: members file nothing. The two INSERT policies that let a member write
-- (`loans`, `payment_submissions`) are dropped. From here every transaction is
-- keyed by an admin — see 036.
--
-- HALF TWO: make the admin gate actually hold. The gate was not merely permissive,
-- it was open. This schema contains exactly TWO `REVOKE` statements, so every other
-- function keeps Postgres' default EXECUTE TO PUBLIC — and ten SECURITY DEFINER
-- functions have no authorization check in their body at all. `execute_role_change`
-- checks only `status = 'pending'` before running `UPDATE profiles SET role`. Three
-- of the ten have their request ids handed to members by `USING (auth.uid() IS NOT
-- NULL)` SELECT policies, which closes the loop into a self-serve exploit: read a
-- pending id, apply it. A member could promote themselves to admin. A borrower
-- could write off their own loan. None of that needed a bug — just the documented
-- default privilege nobody revoked.
--
-- The `execute_*` family was always meant to be internal; every one of them carries
-- a comment saying "never call directly from the client" (setup.sql:1188, 2469,
-- 2250, 1923). Comments are not privileges. This migration writes the REVOKEs those
-- comments assumed.
--
-- Requires 033.

-- --------------------------------------------------------------------------
-- 1. The gate itself.
--
--    is_admin() was the only SECURITY DEFINER function in the schema without a
--    pinned search_path, and the only admin-counting query that did not check
--    is_active — required_approvals() and execute_role_change both do. So a
--    deactivated admin, or one mid-removal, still passed every RLS policy and
--    every RPC guard in the app.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
     WHERE id = auth.uid() AND role = 'admin' AND is_active = true
  );
$$;

-- Companion for the member-read policies below. "Signed in" is not the same as
-- "a member of this group": a pending or removed profile still holds a valid JWT.
CREATE OR REPLACE FUNCTION is_active_member()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND is_active = true
  );
$$;

-- --------------------------------------------------------------------------
-- 2. Revoke the ten unguarded SECURITY DEFINER functions.
--
--    No function body changes. Each is reached only via PERFORM from inside its
--    matching approve_* (which is SECURITY DEFINER and runs as owner) or, for
--    send_due_reminders, from pg_cron as superuser. Both callers are unaffected by
--    a revoke — only the direct client path dies, which is the whole point.
--
--    REVOKING FROM `PUBLIC` ALONE IS NOT ENOUGH ON SUPABASE, and this is the trap
--    the existing code fell into. Supabase ships
--        ALTER DEFAULT PRIVILEGES IN SCHEMA public
--          GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;
--    so every function these migrations create is granted to `authenticated`
--    EXPLICITLY, on top of the implicit PUBLIC grant. Dropping PUBLIC leaves the
--    explicit grant standing and the function still reachable through PostgREST.
--    032's `REVOKE ALL ON FUNCTION schedule_notification_drain FROM public` and its
--    comment ("`authenticated` is never granted EXECUTE") are wrong for exactly
--    this reason; it is corrected below.
--
--    Naming all three is the only form that actually closes the door. The SQL test
--    harness reproduces Supabase's grants faithfully (fixtures.sql), which is what
--    caught this.
-- --------------------------------------------------------------------------

REVOKE ALL ON FUNCTION execute_member_deletion(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_savings_edit(uuid)    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_pool_edit(uuid)       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_role_change(uuid)     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_setting_change(uuid)  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_loan_action(uuid)     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_cycle_close(uuid)     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_social_grant(uuid)    FROM PUBLIC, anon, authenticated;

-- Not an execute_* but the same shape of hole: arbitrary title/body to any
-- recipient on the sms channel — metered spend, and a phishing channel that
-- arrives looking like a trusted group message.
REVOKE ALL ON FUNCTION enqueue_delivery(uuid, text, text, uuid, text)
  FROM PUBLIC, anon, authenticated;

-- Fans a full reminder sweep out to the whole group on demand. pg_cron still
-- calls it; a member no longer can.
REVOKE ALL ON FUNCTION send_due_reminders() FROM PUBLIC, anon, authenticated;

-- 032 intended this one to be unreachable and said so in a comment. Make it true.
REVOKE ALL ON FUNCTION schedule_notification_drain(text, text, text)
  FROM PUBLIC, anon, authenticated;

-- --------------------------------------------------------------------------
-- 3. Close the 2-of-N bypass on roles.
--
--    `CREATE POLICY "Admin can update any profile" ON profiles FOR UPDATE
--     USING (is_admin())` has no WITH CHECK, so Postgres reuses USING as the
--    check — which is caller-scoped, not row-scoped. Any single admin could
--    `update profiles set role='admin'` straight from the browser client and skip
--    request_role_change -> approve_role_change entirely. The whole 2-of-N
--    apparatus for role changes was bypassable by exactly the population it exists
--    to constrain.
--
--    A WITH CHECK cannot fix this: RLS check expressions cannot see OLD, so the
--    policy has no way to say "role must not change". The privilege system can.
--    No client code writes profiles directly — every `.from('profiles')` in src/ is
--    a .select(), and all seven SQL writers are SECURITY DEFINER functions running
--    as owner (update_own_profile, update_own_phone, update_notification_prefs,
--    execute_role_change, approve_member, request_member_exit, the 026 backfill).
--    So revoking UPDATE from `authenticated` outright costs nothing and closes it.
-- --------------------------------------------------------------------------

REVOKE UPDATE ON profiles FROM authenticated;

-- The policy is deliberately left in place. It is now unreachable — the missing
-- GRANT is the real gate, not the policy — but if a future feature grants column
-- level UPDATE back (say admins editing member KYC in the UI), RLS must already be
-- correct underneath it. Do NOT grant role or is_active: those belong to the voted
-- RPCs alone.
COMMENT ON TABLE profiles IS
  'UPDATE is revoked from `authenticated` (034). All writes go through SECURITY DEFINER RPCs. Never grant UPDATE on role or is_active — they are governed by request_role_change / approve_role_change (2-of-N) and approve_member.';

-- --------------------------------------------------------------------------
-- 4. Members file nothing.
--
--    These were the only two INSERT policies a member had on a money table, and
--    both were loose beyond the member-scoping: the loans policy constrained only
--    member_id and status, so any principal was insertable (the cap lives in
--    approve_loan) and the one-open-loan rule was client-side only. The
--    payment_submissions policy never bound related_id to member_id, so a member
--    could file a pending submission against ANOTHER member's fee and block their
--    real payment with "already under review".
--
--    Both problems disappear with the policies.
-- --------------------------------------------------------------------------

DROP POLICY IF EXISTS "Member inserts loan request"   ON loans;
DROP POLICY IF EXISTS "Member inserts own submission" ON payment_submissions;

-- SELECT policies stay: members still see their own loans and submissions.

-- --------------------------------------------------------------------------
-- 5. "Signed in" is not "a member".
--
--    Thirteen tables were readable by anyone holding a JWT, including a pending
--    or deactivated profile — group settings, cycles, distributions, every
--    withdrawal request, meeting minutes, the social fund. Self-registration is
--    being removed in this same release, but is_active=false also covers exited
--    and suspended members, so the scoping matters regardless.
--
--    Group transparency is deliberate and preserved: an ACTIVE member still reads
--    all of this, plus the member directory, income statement and balance sheet.
-- --------------------------------------------------------------------------

DROP POLICY IF EXISTS "Everyone reads group settings" ON group_settings;
CREATE POLICY "Active members read group settings" ON group_settings
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads setting changes" ON setting_changes;
CREATE POLICY "Active members read setting changes" ON setting_changes
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads earnings" ON earnings_ledger;
CREATE POLICY "Active members read earnings" ON earnings_ledger
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads cycles" ON cycles;
CREATE POLICY "Active members read cycles" ON cycles
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads distributions" ON distributions;
CREATE POLICY "Active members read distributions" ON distributions
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads cycle closures" ON cycle_closures;
CREATE POLICY "Active members read cycle closures" ON cycle_closures
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads withdrawals" ON withdrawal_requests;
CREATE POLICY "Active members read withdrawals" ON withdrawal_requests
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads meetings" ON meetings;
CREATE POLICY "Active members read meetings" ON meetings
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads attendance" ON meeting_attendance;
CREATE POLICY "Active members read attendance" ON meeting_attendance
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads social fund" ON social_fund_entries;
CREATE POLICY "Active members read social fund" ON social_fund_entries
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads grant requests" ON social_fund_grant_requests;
CREATE POLICY "Active members read grant requests" ON social_fund_grant_requests
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Anyone signed in reads templates" ON notification_templates;
CREATE POLICY "Active members read templates" ON notification_templates
  FOR SELECT USING (is_active_member() OR is_admin());

-- loan_guarantors is intentionally not re-scoped here; 035 drops the table.

-- --------------------------------------------------------------------------
-- 6. The read RPCs and views that leaked past the base-table RLS.
--
--    Every read RPC is SECURITY DEFINER, so the caller's RLS never applies; the
--    in-body check IS the scope. Only member_ledger (029) ever had one. The rest
--    returned whole-group per-member financials to anybody signed in.
--
--    What stays open to members is a deliberate choice, not an oversight:
--    group_member_directory (savings + loan per member), group_income_statement
--    and group_balance_sheet. This group runs on transparency; losing the ability
--    to file a transaction is not the same as losing sight of the books.
--
--    What closes is per-member operational detail with no transparency purpose:
--    another member's withdrawable balance, the per-member cycle basis, the
--    share-out preview, and the whole-group member report.
-- --------------------------------------------------------------------------

-- cycle_earnings, preview_cycle_close and group_member_report are deliberately
-- LEFT OPEN to members. They are read-only, carry no PII, and sit inside the
-- transparency envelope this group has chosen: if the income statement and balance
-- sheet are open, a cycle's earnings and the share-out preview that follows from
-- them are not a secret. They are also called straight from the browser
-- (src/lib/cycles.js:28,36, src/lib/reports.js:24), so a REVOKE here would break
-- /admin/cycles and /admin/reports rather than protect anything.
--
-- member_withdrawable is the exception — one member's withdrawable balance is
-- operational detail about them, not group transparency. It gets a self-or-admin
-- guard in 035, which has to rewrite its body anyway to drop the guarantor term.

-- Per-member views that ran as owner (RLS-bypassing) and were granted to every
-- authenticated user. 027 set security_invoker on four member-scoped views and
-- missed these two — same class of bug, same fix.
ALTER VIEW v_member_capital_events SET (security_invoker = true);
ALTER VIEW v_loan_risk             SET (security_invoker = true);

-- --------------------------------------------------------------------------
-- 7. Retire whatever is still in flight.
--
--    Members can no longer file, so anything already pending would sit in the
--    admin queue forever with no way for its author to withdraw or amend it.
--    Reject it explicitly and tell each member why, rather than leaving rows
--    stranded in a queue that no longer has an intake.
--
--    Admins re-key any of these that were genuine, through the new flows in 036.
-- --------------------------------------------------------------------------

INSERT INTO notification_templates (kind, lang, title, body) VALUES
  ('intake_superseded', 'sw', 'Ombi lako limefungwa',
   'Malipo na maombi sasa yanaandikwa na msimamizi. Wasiliana na msimamizi wako.'),
  ('intake_superseded', 'en', 'Your request was closed',
   'Payments and requests are now recorded by an admin. Please speak to your admin.')
ON CONFLICT (kind, lang) DO UPDATE
  SET title = EXCLUDED.title, body = EXCLUDED.body;

DO $$
DECLARE
  v_reason text := 'Superseded — payments are now recorded by admins.';
  v_subs   int;
  v_loans  int;
  v_wdr    int;
BEGIN
  -- Notify first, off the rows we are about to change, so each member gets one
  -- message per stranded item. 033's BEFORE INSERT trigger renders it in their
  -- own language from the templates above.
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT member_id, 'intake_superseded', 'Your request was closed', NULL,
         jsonb_build_object('source', 'payment_submission', 'id', id)
    FROM payment_submissions WHERE status = 'pending';

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT member_id, 'intake_superseded', 'Your request was closed', NULL,
         jsonb_build_object('source', 'loan', 'id', id)
    FROM loans WHERE status = 'pending';

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT member_id, 'intake_superseded', 'Your request was closed', NULL,
         jsonb_build_object('source', 'withdrawal_request', 'id', id)
    FROM withdrawal_requests WHERE status = 'pending';

  UPDATE payment_submissions
     SET status = 'rejected', reviewed_at = now(), rejection_reason = v_reason
   WHERE status = 'pending';
  GET DIAGNOSTICS v_subs = ROW_COUNT;

  UPDATE loans
     SET status = 'rejected', rejection_reason = v_reason
   WHERE status = 'pending';
  GET DIAGNOSTICS v_loans = ROW_COUNT;

  UPDATE withdrawal_requests
     SET status = 'rejected', rejection_reason = v_reason
   WHERE status = 'pending';
  GET DIAGNOSTICS v_wdr = ROW_COUNT;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (NULL, 'admin_mandate_lockdown', 'migration', NULL,
          jsonb_build_object('submissions_rejected', v_subs,
                             'loans_rejected',       v_loans,
                             'withdrawals_rejected', v_wdr));
END;
$$;

-- ---------------------------------------------------------------------------
-- 035_drop_guarantors.sql
-- ---------------------------------------------------------------------------

-- 035_drop_guarantors.sql — remove guarantees entirely.
--
-- Guarantees were the one member-to-member mechanism in the app: a borrower
-- nominated, a nominee accepted, and accepting locked part of the NOMINEE's savings
-- against somebody else's debt. Under the admin mandate there is no member action
-- left to give that consent with, and an admin assigning a lock over another
-- member's savings without their tap is a different and worse thing than what 028
-- built. So the feature goes rather than being quietly converted.
--
-- DESTRUCTIVE. `loan_guarantors` is dropped, not archived — pledge history does not
-- survive this. Take a backup first. Money that guarantees actually moved is NOT in
-- this table and is untouched: called guarantees wrote `savings_adjustments` +
-- `loan_recoveries` rows in 022's format, and those stay exactly where they are, so
-- the pool arithmetic is unaffected.
--
-- Locks release automatically. Nothing stores "locked" as a value; it was computed
-- inside member_withdrawable() by summing accepted pledges. Once the table is gone
-- the term is gone, and every guarantor's savings are free — which is why the
-- notification below goes out BEFORE the drop, while there is still something to
-- read.
--
-- Requires 034.

-- --------------------------------------------------------------------------
-- 1. Tell anyone whose savings are about to come unlocked.
-- --------------------------------------------------------------------------

INSERT INTO notification_templates (kind, lang, title, body) VALUES
  ('guarantee_ended', 'sw', 'Dhamana yako imefungwa',
   'Akiba yako iliyokuwa imezuiliwa kwa dhamana sasa ipo huru.'),
  ('guarantee_ended', 'en', 'Your guarantee has ended',
   'The savings that were locked against a guarantee are now free.')
ON CONFLICT (kind, lang) DO UPDATE
  SET title = EXCLUDED.title, body = EXCLUDED.body;

DO $$
DECLARE
  v_freed int;
BEGIN
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT DISTINCT g.guarantor_id, 'guarantee_ended', 'Your guarantee has ended', NULL,
         jsonb_build_object('loan_id', g.loan_id)
    FROM loan_guarantors g
    JOIN loans l ON l.id = g.loan_id
   WHERE g.status IN ('pending', 'accepted')
     AND l.status IN ('pending', 'active');
  GET DIAGNOSTICS v_freed = ROW_COUNT;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (NULL, 'drop_guarantors', 'migration', NULL,
          jsonb_build_object(
            'guarantors_notified', v_freed,
            'pledges_dropped', (SELECT count(*) FROM loan_guarantors)));
END;
$$;

-- --------------------------------------------------------------------------
-- 2. member_withdrawable — without the pledge term, and scoped.
--
--    Two changes in one rewrite because a plpgsql function has to be replaced
--    whole either way.
--
--    (a) The pledge subtraction goes with the table.
--    (b) It gains the self-or-admin guard that 034 flagged. Every read RPC in this
--        schema is SECURITY DEFINER, so the caller's RLS never applies and the
--        in-body check IS the scope; member_ledger (029) was the only one that had
--        one. A member's withdrawable balance and how much of it is locked behind
--        their own loan is operational detail about them, not the group
--        transparency the directory and the income statement provide.
--
--    All three surviving callers are safe under the guard: request_withdrawal
--    passes auth.uid(), and approve_withdrawal and request_member_exit are both
--    admin-guarded already.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION member_withdrawable(p_member_id uuid)
RETURNS TABLE (
  savings_tzs      numeric,
  outstanding_tzs  numeric,
  locked_tzs       numeric,
  pool_tzs         numeric,
  withdrawable_tzs numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_member_id <> auth.uid() AND NOT is_admin() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  RETURN QUERY
  WITH s AS (
    SELECT
        COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                   WHERE member_id = p_member_id
                     AND submission_type = 'savings_deposit'
                     AND status = 'approved'), 0)
      + COALESCE((SELECT SUM(amount_paid) FROM monthly_fees
                   WHERE member_id = p_member_id), 0)
      + COALESCE((SELECT SUM(delta) FROM savings_adjustments
                   WHERE target_member_id = p_member_id AND status = 'approved'), 0)
      - COALESCE((SELECT SUM(amount) FROM withdrawal_requests
                   WHERE member_id = p_member_id AND status IN ('pending', 'approved')), 0)
        AS savings,
      COALESCE((SELECT SUM(COALESCE(outstanding_principal, principal))
                  FROM loans WHERE member_id = p_member_id AND status = 'active'), 0)
        AS outstanding,
      (SELECT pool_balance_tzs FROM v_group_pool) AS pool
  ),
  l AS (
    SELECT s.*,
      CASE WHEN s.outstanding > 0
           THEN ceil(s.outstanding / greatest(setting('contribution_multiplier'), 1))
           ELSE 0 END AS locked
    FROM s
  )
  SELECT
    l.savings,
    l.outstanding,
    l.locked,
    l.pool,
    greatest(least(l.savings - l.locked, l.pool), 0)
  FROM l;
END;
$$;

-- --------------------------------------------------------------------------
-- 3. approve_loan — without guarantees, and without the self-approval block.
--
--    Same reasoning as above: one function, one rewrite. Three changes, all
--    belonging to this release.
--
--    (a) The unanswered-nomination check goes with the feature.
--    (b) The `guarantors` count in the audit payload goes with the table.
--    (c) `IF v_loan.member_id = auth.uid() THEN RAISE 'Cannot approve your own
--        loan'` is REMOVED. It was correct while members filed their own requests:
--        an admin who submitted a loan could not also wave it through. Now that
--        loans are filed BY admins (036), that same line means an admin can never
--        borrow at all — the group's own rule is that an admin is a contributing
--        member like anyone else (Decision #1). 2-of-N still applies, and
--        loan_approvals has a UNIQUE (loan_id, admin_id), so the borrower-admin
--        still cannot supply both signatures. A second admin must sign.
--
--    Everything else is the 028 body verbatim, including the rule that not all
--    admins may hold loans at once.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_loan(p_loan_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_loan              loans%ROWTYPE;
  v_int               numeric(12,2);
  v_pool              numeric(14,2);
  v_contribution      numeric(14,2);
  v_required          int;
  v_approvals         int;
  v_final_proof       text;
  v_other_admin_loans int;
  v_total_admins      int;
  v_fraction          numeric := setting('pool_loan_fraction');
  v_multiplier        numeric := setting('contribution_multiplier');
  v_rate              numeric := setting('loan_interest_rate');
  v_months            int     := setting('default_loan_months')::int;
  v_n                 int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL          THEN RAISE EXCEPTION 'Loan not found';      END IF;
  IF v_loan.status <> 'pending' THEN RAISE EXCEPTION 'Loan is not pending'; END IF;

  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;
  IF v_loan.principal > floor(v_fraction * COALESCE(v_pool, 0)) THEN
    RAISE EXCEPTION 'Loan exceeds % of the group pool (max %).',
      round(v_fraction * 100) || '%', floor(v_fraction * COALESCE(v_pool, 0));
  END IF;

  SELECT
      COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                WHERE member_id = v_loan.member_id
                  AND submission_type = 'savings_deposit'
                  AND status = 'approved'), 0)
    + COALESCE((SELECT SUM(amount) FROM monthly_fees
                WHERE member_id = v_loan.member_id AND status = 'paid'), 0)
  INTO v_contribution;
  IF v_loan.principal > floor(v_multiplier * v_contribution) THEN
    RAISE EXCEPTION 'Loan exceeds %x member contribution (max %).',
      v_multiplier, floor(v_multiplier * v_contribution);
  END IF;

  BEGIN
    INSERT INTO loan_approvals (loan_id, admin_id, proof_url)
    VALUES (p_loan_id, auth.uid(), p_proof_url);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this loan';
  END;

  v_required := required_approvals();
  SELECT count(*) INTO v_approvals FROM loan_approvals WHERE loan_id = p_loan_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_loan', 'loan', p_loan_id,
            jsonb_build_object(
              'member_id', v_loan.member_id,
              'principal', v_loan.principal,
              'approvals', v_approvals,
              'required',  v_required
            ));
    RETURN;
  END IF;

  IF (SELECT role FROM profiles WHERE id = v_loan.member_id) = 'admin' THEN
    SELECT count(*) INTO v_total_admins
      FROM profiles WHERE role = 'admin' AND is_active = true;
    SELECT count(*) INTO v_other_admin_loans
      FROM loans
      WHERE status = 'active'
        AND member_id IN (SELECT id FROM profiles WHERE role = 'admin' AND is_active = true)
        AND member_id <> v_loan.member_id;
    IF v_other_admin_loans >= v_total_admins - 1 THEN
      RAISE EXCEPTION 'Not all admins may hold loans simultaneously; one admin must remain loan-free.';
    END IF;
  END IF;

  SELECT proof_url INTO v_final_proof
  FROM loan_approvals WHERE loan_id = p_loan_id
  ORDER BY approved_at ASC LIMIT 1;

  v_int := round(v_loan.principal * v_rate);

  UPDATE loans
    SET status = 'active',
        approved_at = now(),
        approved_by = auth.uid(),
        disbursed_at = now(),
        disbursement_proof_url = v_final_proof,
        outstanding_principal = v_loan.principal,
        interest_rate = v_rate
    WHERE id = p_loan_id;

  FOR v_n IN 1..v_months LOOP
    INSERT INTO loan_installments
      (loan_id, installment_number, due_date, principal_due, interest_due, penalty_rate)
    VALUES (
      p_loan_id,
      v_n,
      (today_eat() + (v_n || ' month')::interval)::date,
      CASE WHEN v_n = v_months THEN v_loan.principal ELSE 0 END,
      v_int,
      setting('penalty_rate')
    );
  END LOOP;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_loan', 'loan', p_loan_id,
          jsonb_build_object(
            'member_id',     v_loan.member_id,
            'principal',     v_loan.principal,
            'approvals',     v_approvals,
            'interest_rate', v_rate,
            'months',        v_months
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 4. Drop the feature.
-- --------------------------------------------------------------------------

DROP TRIGGER IF EXISTS on_loan_close_release_guarantees ON loans;
DROP FUNCTION IF EXISTS release_guarantees_on_loan_close();

DROP FUNCTION IF EXISTS nominate_guarantor(uuid, uuid, numeric);
DROP FUNCTION IF EXISTS respond_to_guarantee(uuid, boolean);
DROP FUNCTION IF EXISTS cancel_guarantee(uuid);
DROP FUNCTION IF EXISTS call_guarantees(uuid, text);

DROP TABLE IF EXISTS loan_guarantors;

-- ---------------------------------------------------------------------------
-- 036_admin_recording.sql
-- ---------------------------------------------------------------------------

-- 036_admin_recording.sql — admins key every transaction.
--
-- 034 removed the member's ability to file. This puts the intake back on the admin
-- side, without reimplementing a single line of the money logic.
--
-- THE ONE IDEA HERE: `approve_submission` was two things welded together — a 2-of-N
-- signature tally, and the settlement waterfall (penalty -> interest -> principal,
-- fee part-payment, early-principal retirement, loan closing, re-pricing the
-- remaining installments, the earnings ledger). Only the first half is about who
-- may act. This migration splits the second half out as `settle_submission()` and
-- has all three intake paths call it, so there is exactly one implementation of the
-- waterfall in the schema and the new paths cannot drift from the tested one.
--
-- WHO SIGNS WHAT (the group's decisions, not defaults):
--   monthly fee, another member      -> ONE admin. It is a fixed, predictable
--                                      amount; batching 15 of them behind a second
--                                      signature every month is friction with no
--                                      information in it.
--   savings deposit, loan repayment  -> TWO admins. The amount varies, so a second
--                                      pair of eyes is worth the delay.
--   an admin's OWN money, any type   -> TWO admins, always. The recorder cannot be
--                                      the only signature on their own account.
--
-- Requires 035.

-- --------------------------------------------------------------------------
-- 1. Schema: an admin-keyed row is not a member-uploaded proof.
--
--    proof_url was NOT NULL because the row's whole purpose was to carry a
--    screenshot a member had uploaded. An admin recording from the M-Pesa SMS on
--    their own phone often has nothing to attach, and inventing a placeholder
--    string to satisfy a constraint would put junk in the audit trail.
--
--    recorded_by keeps the two eras distinguishable forever: NULL means a member
--    filed it themselves, before this release.
-- --------------------------------------------------------------------------

ALTER TABLE payment_submissions ALTER COLUMN proof_url DROP NOT NULL;
ALTER TABLE payment_submissions
  ADD COLUMN IF NOT EXISTS recorded_by uuid REFERENCES profiles(id);

COMMENT ON COLUMN payment_submissions.recorded_by IS
  'The admin who keyed this entry (036). NULL for rows a member filed themselves, which is every row created before the admin mandate.';

-- --------------------------------------------------------------------------
-- 2. settle_submission — the waterfall, lifted verbatim out of approve_submission.
--
--    Body is byte-for-byte the settlement half of the 021 version: same ordering,
--    same ceilings, same earnings_ledger entries, same loan-closing and re-pricing
--    rules. What is NOT here is the authorization check, the signature tally and
--    the audit row — those belong to the caller, which is the point of the split.
--
--    Private. It moves money with no permission check of its own, so it must never
--    be reachable from PostgREST. This is exactly the shape of the eight functions
--    034 had to revoke; the REVOKE ships in the same breath as the definition this
--    time, and names anon/authenticated as well as PUBLIC because Supabase's
--    default privileges grant to those roles explicitly.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION settle_submission(p_submission_id uuid, p_amount numeric)
RETURNS void AS $$
DECLARE
  s                 payment_submissions%ROWTYPE;
  v_left            numeric(12,2);
  v_penalty         numeric(12,2);
  v_pay             numeric(12,2);
  v_fee             monthly_fees%ROWTYPE;
  v_fee_remaining   numeric(12,2);
  v_inst            loan_installments%ROWTYPE;
  v_loan_id         uuid;
  v_int_remaining   numeric(12,2);
  v_prin_remaining  numeric(12,2);
  v_interest_pay    numeric(12,2);
  v_principal_pay   numeric(12,2);
  v_extra_principal numeric(12,2);
  v_outstanding     numeric(12,2);
  v_rate            numeric;
  v_new_int         numeric(12,2);
  v_last            int;
  v_interest_open   int;
BEGIN
  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Submission not found'; END IF;

  UPDATE payment_submissions
    SET status = 'approved', reviewed_at = now(), reviewed_by = auth.uid()
    WHERE id = p_submission_id;

  v_left := p_amount;

  -- ---------------------------------------------------------------- monthly fee
  IF s.submission_type = 'monthly_fee' THEN
    SELECT * INTO v_fee FROM monthly_fees WHERE id = s.related_id FOR UPDATE;
    IF v_fee.id IS NULL THEN RAISE EXCEPTION 'Monthly fee not found'; END IF;

    SELECT COALESCE(penalty_due, 0) INTO v_penalty
      FROM v_fee_status_money WHERE id = v_fee.id;
    v_fee_remaining := greatest(v_fee.amount - v_fee.amount_paid, 0);

    IF v_left > v_penalty + v_fee_remaining THEN
      RAISE EXCEPTION
        'Payment of % exceeds the % still owed on this fee (% base + % penalty). Record the exact amount and log any surplus as a savings deposit.',
        v_left, v_penalty + v_fee_remaining, v_fee_remaining, v_penalty;
    END IF;

    v_pay  := least(v_left, v_penalty);          -- penalty first
    v_left := v_left - v_pay;
    UPDATE monthly_fees
       SET penalty_collected = penalty_collected + v_pay,
           amount_paid       = amount_paid + least(v_left, v_fee_remaining),
           reviewed_by       = auth.uid()
     WHERE id = v_fee.id;

    UPDATE monthly_fees
       SET status  = CASE WHEN amount_paid >= amount THEN 'paid' ELSE 'partial' END,
           paid_at = CASE WHEN amount_paid >= amount THEN now() ELSE paid_at END
     WHERE id = v_fee.id;

    IF v_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'penalty', v_pay, p_submission_id, 'monthly_fee', v_fee.id);
    END IF;

  -- ----------------------------------------------------------- loan installment
  ELSIF s.submission_type = 'loan_installment' THEN
    SELECT * INTO v_inst FROM loan_installments WHERE id = s.related_id FOR UPDATE;
    IF v_inst.id IS NULL THEN RAISE EXCEPTION 'Installment not found'; END IF;
    v_loan_id := v_inst.loan_id;

    SELECT COALESCE(penalty_due, 0) INTO v_penalty
      FROM v_installment_status_money WHERE id = v_inst.id;

    v_int_remaining  := greatest(v_inst.interest_due  - v_inst.interest_paid,  0);
    v_prin_remaining := greatest(v_inst.principal_due - v_inst.principal_paid, 0);

    SELECT outstanding_principal, interest_rate INTO v_outstanding, v_rate
      FROM loans WHERE id = v_loan_id FOR UPDATE;

    IF v_left > v_penalty + v_int_remaining + v_outstanding THEN
      RAISE EXCEPTION
        'Payment of % exceeds everything outstanding on this loan (%). Record the exact amount and log any surplus as a savings deposit.',
        v_left, v_penalty + v_int_remaining + v_outstanding;
    END IF;

    v_pay  := least(v_left, v_penalty);               -- 1. penalty
    v_left := v_left - v_pay;

    v_interest_pay := least(v_left, v_int_remaining); -- 2. interest
    v_left := v_left - v_interest_pay;

    v_principal_pay := least(v_left, v_prin_remaining); -- 3. contracted principal
    v_left := v_left - v_principal_pay;

    -- 4. anything still left retires principal early
    v_extra_principal := least(v_left, greatest(v_outstanding - v_principal_pay, 0));

    UPDATE loan_installments
       SET penalty_collected = penalty_collected + v_pay,
           interest_paid     = interest_paid + v_interest_pay,
           principal_paid    = principal_paid + v_principal_pay + v_extra_principal,
           reviewed_by       = auth.uid()
     WHERE id = v_inst.id;

    UPDATE loan_installments
       SET status  = CASE
                       WHEN interest_paid >= interest_due AND principal_paid >= principal_due
                       THEN 'paid' ELSE 'partial'
                     END,
           paid_at = CASE
                       WHEN interest_paid >= interest_due AND principal_paid >= principal_due
                       THEN now() ELSE paid_at
                     END
     WHERE id = v_inst.id;

    v_outstanding := v_outstanding - v_principal_pay - v_extra_principal;
    UPDATE loans SET outstanding_principal = v_outstanding WHERE id = v_loan_id;

    IF v_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'penalty', v_pay, p_submission_id, 'loan_installment', v_inst.id);
    END IF;
    IF v_interest_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'interest', v_interest_pay, p_submission_id, 'loan_installment', v_inst.id);
    END IF;

    SELECT count(*) INTO v_interest_open
      FROM loan_installments
     WHERE loan_id = v_loan_id
       AND status <> 'cancelled'
       AND interest_paid < interest_due;

    IF v_outstanding <= 0 AND v_interest_open = 0 THEN
      UPDATE loans SET status = 'closed' WHERE id = v_loan_id;
      UPDATE loan_installments
         SET status = 'cancelled'
       WHERE loan_id = v_loan_id AND status = 'pending';
    ELSE
      v_new_int := round(v_outstanding * COALESCE(v_rate, 0.05));
      SELECT max(installment_number) INTO v_last
        FROM loan_installments WHERE loan_id = v_loan_id AND status <> 'cancelled';

      UPDATE loan_installments
         SET interest_due  = v_new_int,
             principal_due = CASE WHEN installment_number = v_last THEN v_outstanding ELSE 0 END
       WHERE loan_id = v_loan_id
         AND status = 'pending';
    END IF;

  -- --------------------------------------------------------------------- savings
  ELSE
    UPDATE payment_submissions SET amount_claimed = p_amount
      WHERE id = p_submission_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION settle_submission(uuid, numeric) FROM PUBLIC, anon, authenticated;

-- --------------------------------------------------------------------------
-- 3. approve_submission — now just the tally, delegating the money.
--
--    Identical behaviour to the 021 version. The self-approval block stays: it is
--    what stops the admin who recorded their own payment from also being its
--    second signature.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_submission(p_submission_id uuid, p_amount_received numeric)
RETURNS void AS $$
DECLARE
  s              payment_submissions%ROWTYPE;
  v_required     int;
  v_approvals    int;
  v_final_amount numeric(12,2);
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_amount_received IS NULL OR p_amount_received <= 0 THEN
    RAISE EXCEPTION 'Invalid amount received';
  END IF;

  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id FOR UPDATE;
  IF s.id IS NULL             THEN RAISE EXCEPTION 'Submission not found'; END IF;
  IF s.status <> 'pending'    THEN RAISE EXCEPTION 'Already reviewed';    END IF;
  IF s.member_id = auth.uid() THEN RAISE EXCEPTION 'Cannot approve your own submission'; END IF;

  BEGIN
    INSERT INTO submission_approvals (submission_id, admin_id, amount_received)
    VALUES (p_submission_id, auth.uid(), p_amount_received);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this submission';
  END;

  v_required := submission_threshold(p_submission_id);
  SELECT count(*) INTO v_approvals FROM submission_approvals WHERE submission_id = p_submission_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_submission', 'submission', p_submission_id,
            jsonb_build_object(
              'submission_type', s.submission_type,
              'member_id',       s.member_id,
              'amount_received', p_amount_received,
              'approvals',       v_approvals,
              'required',        v_required
            ));
    RETURN;
  END IF;

  -- The first signature's figure is the one that settles (Decision #11).
  SELECT amount_received INTO v_final_amount
  FROM submission_approvals
  WHERE submission_id = p_submission_id
  ORDER BY approved_at ASC
  LIMIT 1;

  PERFORM settle_submission(p_submission_id, v_final_amount);

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_submission', 'submission', p_submission_id,
          jsonb_build_object(
            'submission_type', s.submission_type,
            'member_id',       s.member_id,
            'amount_received', v_final_amount,
            'approvals',       v_approvals
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 4. How many signatures does THIS submission need?
--
--    required_approvals() answers for the group (least(2, active admins)). This
--    answers for one row, because the group decided the threshold varies by what
--    is being recorded — and because an admin's own money is never a one-signature
--    matter regardless of how few admins there are.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION submission_threshold(p_submission_id uuid)
RETURNS int AS $$
DECLARE
  s payment_submissions%ROWTYPE;
BEGIN
  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id;
  IF s.id IS NULL THEN RETURN required_approvals(); END IF;

  -- An admin's own money: two signatures, always. greatest(...,2) rather than
  -- required_approvals() so a one-admin group cannot degrade this to a single
  -- signature the way every other flow does.
  IF s.recorded_by IS NOT NULL AND s.recorded_by = s.member_id THEN
    RETURN greatest(required_approvals(), 2);
  END IF;

  -- A monthly fee recorded by an admin for someone else: one signature. Fixed
  -- amount, fixed due date, nothing to second-guess.
  IF s.recorded_by IS NOT NULL AND s.submission_type = 'monthly_fee' THEN
    RETURN 1;
  END IF;

  RETURN required_approvals();
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. record_payment — one entry, any type.
--
--    Creates the row AND casts the recording admin's signature in one call, then
--    settles if that already meets the row's threshold. A second admin, when one is
--    needed, completes it through the ordinary approve_submission queue.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION record_payment(
  p_member_id  uuid,
  p_type       text,
  p_related_id uuid,
  p_amount     numeric,
  p_proof_url  text DEFAULT NULL
)
RETURNS uuid AS $$
DECLARE
  v_id        uuid;
  v_self      boolean;
  v_admins    int;
  v_required  int;
  v_approvals int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Enter an amount greater than zero';
  END IF;
  IF p_type NOT IN ('savings_deposit', 'monthly_fee', 'loan_installment') THEN
    RAISE EXCEPTION 'Unknown payment type: %', p_type;
  END IF;
  IF p_type IN ('monthly_fee', 'loan_installment') AND p_related_id IS NULL THEN
    RAISE EXCEPTION 'Choose which fee or installment this payment settles';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_member_id AND is_active = true) THEN
    RAISE EXCEPTION 'That member is not active';
  END IF;

  v_self := (p_member_id = auth.uid());

  -- Fail here, not silently later. Without a second admin this row could never
  -- reach its threshold and would sit pending forever with no way to finish it.
  IF v_self THEN
    SELECT count(*) INTO v_admins FROM profiles WHERE role = 'admin' AND is_active = true;
    IF v_admins < 2 THEN
      RAISE EXCEPTION 'A second admin is required to record your own payment. Promote another admin first.';
    END IF;
  END IF;

  INSERT INTO payment_submissions
    (member_id, submission_type, related_id, amount_claimed, proof_url, recorded_by)
  VALUES (p_member_id, p_type, p_related_id, p_amount, p_proof_url, auth.uid())
  RETURNING id INTO v_id;

  INSERT INTO submission_approvals (submission_id, admin_id, amount_received)
  VALUES (v_id, auth.uid(), p_amount);

  v_required := submission_threshold(v_id);
  SELECT count(*) INTO v_approvals FROM submission_approvals WHERE submission_id = v_id;

  IF v_approvals >= v_required THEN
    PERFORM settle_submission(v_id, p_amount);
  ELSE
    INSERT INTO notifications (recipient_id, kind, title, body, data)
    SELECT p.id, 'payment_awaiting_signature',
           'A payment needs your signature',
           NULL,
           jsonb_build_object('submission_id', v_id)
      FROM profiles p
     WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();
  END IF;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'record_payment', 'submission', v_id,
          jsonb_build_object(
            'submission_type', p_type,
            'member_id',       p_member_id,
            'amount',          p_amount,
            'self_recorded',   v_self,
            'approvals',       v_approvals,
            'required',        v_required,
            'settled',         v_approvals >= v_required
          ));

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 6. record_fee_payments — the monthly batch.
--
--    One call posts the whole sheet. Fees are the predictable half of the month's
--    work: ~15 identical amounts against rows the system generated itself, so
--    keying them one at a time behind a second signature is friction with no
--    information in it.
--
--    Entries are `[{"fee_id": uuid, "amount": numeric, "proof_url": text}]`.
--    The member is derived from the fee rather than passed, so a mistyped member
--    cannot be paired with someone else's fee.
--
--    All-or-nothing: one bad entry raises and the whole batch rolls back, so the
--    admin never has to work out which half of a sheet posted.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION record_fee_payments(p_entries jsonb)
RETURNS int AS $$
DECLARE
  v_entry    jsonb;
  v_fee      monthly_fees%ROWTYPE;
  v_amount   numeric(12,2);
  v_sub_id   uuid;
  v_count    int := 0;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_entries IS NULL OR jsonb_typeof(p_entries) <> 'array' THEN
    RAISE EXCEPTION 'Expected an array of fee payments';
  END IF;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_entries) LOOP
    SELECT * INTO v_fee FROM monthly_fees
     WHERE id = (v_entry->>'fee_id')::uuid FOR UPDATE;
    IF v_fee.id IS NULL THEN
      RAISE EXCEPTION 'Monthly fee % not found', v_entry->>'fee_id';
    END IF;

    v_amount := (v_entry->>'amount')::numeric;
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RAISE EXCEPTION 'Enter an amount greater than zero for every member you have ticked';
    END IF;

    -- An admin's own fee is never a one-signature matter. Send it to
    -- record_payment, which collects the second signature properly.
    IF v_fee.member_id = auth.uid() THEN
      RAISE EXCEPTION 'Record your own fee separately — it needs a second admin''s signature.';
    END IF;

    INSERT INTO payment_submissions
      (member_id, submission_type, related_id, amount_claimed, proof_url, recorded_by)
    VALUES (v_fee.member_id, 'monthly_fee', v_fee.id, v_amount,
            NULLIF(v_entry->>'proof_url', ''), auth.uid())
    RETURNING id INTO v_sub_id;

    INSERT INTO submission_approvals (submission_id, admin_id, amount_received)
    VALUES (v_sub_id, auth.uid(), v_amount);

    PERFORM settle_submission(v_sub_id, v_amount);
    v_count := v_count + 1;
  END LOOP;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'record_fee_payments', 'submission', NULL,
          jsonb_build_object('entries', v_count));

  RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 7. file_loan — the admin raises the request the member used to.
--
--    approve_loan (035) still does the disbursing, still needs 2-of-N, still
--    applies both ceilings. This only creates the pending row.
--
--    The one-open-loan rule (Decision #4) is enforced HERE, in SQL, for the first
--    time. It has only ever lived in the client (`submitLoanRequest`), with a
--    comment on the loans table admitting as much — so it was never a rule, just a
--    disabled button. Now that there is exactly one way in, it can be real.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION file_loan(p_member_id uuid, p_principal numeric)
RETURNS uuid AS $$
DECLARE
  v_id   uuid;
  v_name text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_principal IS NULL OR p_principal <= 0 THEN
    RAISE EXCEPTION 'Enter a loan amount greater than zero';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_member_id AND is_active = true) THEN
    RAISE EXCEPTION 'That member is not active';
  END IF;
  IF EXISTS (SELECT 1 FROM loans
              WHERE member_id = p_member_id AND status IN ('pending', 'active')) THEN
    RAISE EXCEPTION 'That member already has a loan in progress';
  END IF;

  INSERT INTO loans (member_id, principal, status)
  VALUES (p_member_id, p_principal, 'pending')
  RETURNING id INTO v_id;

  SELECT full_name INTO v_name FROM profiles WHERE id = p_member_id;

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'loan_filed', 'A loan is waiting for approval',
         COALESCE(v_name, 'A member') || ' — ' || fmt_tzs(p_principal),
         jsonb_build_object('loan_id', v_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'file_loan', 'loan', v_id,
          jsonb_build_object('member_id', p_member_id, 'principal', p_principal));

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 8. Withdrawals move to the admin side.
--
--    Same validation as 025's request_withdrawal, including the member_withdrawable
--    ceiling; only the caller changes. approve_withdrawal (2-of-N) and
--    mark_withdrawal_paid are untouched.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin_request_withdrawal(
  p_member_id uuid, p_amount numeric, p_reason text
)
RETURNS uuid AS $$
DECLARE
  v_id   uuid;
  v_max  numeric(14,2);
  v_name text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_member_id AND is_active = true) THEN
    RAISE EXCEPTION 'That member is not active';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Enter an amount greater than zero';
  END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every withdrawal';
  END IF;
  IF EXISTS (SELECT 1 FROM withdrawal_requests
              WHERE member_id = p_member_id AND status IN ('pending', 'approved')) THEN
    RAISE EXCEPTION 'That member already has a withdrawal in progress';
  END IF;

  SELECT withdrawable_tzs INTO v_max FROM member_withdrawable(p_member_id);
  IF p_amount > v_max THEN
    RAISE EXCEPTION 'They can withdraw at most % right now', v_max;
  END IF;

  INSERT INTO withdrawal_requests (member_id, amount, reason)
  VALUES (p_member_id, p_amount, trim(p_reason))
  RETURNING id INTO v_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'admin_request_withdrawal', 'withdrawal', v_id,
          jsonb_build_object('member_id', p_member_id, 'amount', p_amount, 'reason', p_reason));

  SELECT full_name INTO v_name FROM profiles WHERE id = p_member_id;
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'withdrawal_requested', 'Withdrawal requested',
         COALESCE(v_name, 'A member') || ' — ' || fmt_tzs(p_amount),
         jsonb_build_object('request_id', v_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- The member-facing entry point is gone.
DROP FUNCTION IF EXISTS request_withdrawal(numeric, text);

-- --------------------------------------------------------------------------
-- 9. Messages for the two new notification kinds.
-- --------------------------------------------------------------------------

INSERT INTO notification_templates (kind, lang, title, body) VALUES
  ('payment_awaiting_signature', 'sw', 'Malipo yanasubiri saini yako', NULL),
  ('payment_awaiting_signature', 'en', 'A payment needs your signature', NULL),
  ('loan_filed', 'sw', 'Mkopo unasubiri idhini', NULL),
  ('loan_filed', 'en', 'A loan is waiting for approval', NULL)
ON CONFLICT (kind, lang) DO UPDATE
  SET title = EXCLUDED.title, body = EXCLUDED.body;

-- ---------------------------------------------------------------------------
-- 037_payment_void.sql
-- ---------------------------------------------------------------------------

-- 037_payment_void.sql — undoing an admin's typo.
--
-- Until 036 a wrong figure was a member's wrong figure: they uploaded a screenshot,
-- an admin read it, and if the two disagreed the admin rejected it and the member
-- filed again. Nothing was ever posted by mistake because nothing was posted
-- without being read off a proof.
--
-- Now the admin keys the amount from an M-Pesa SMS, so a mistyped 50,000 for 5,000
-- posts, settles, moves the pool and closes a fee. The old answer — the 2-of-N
-- savings adjustment — patches the member's balance but leaves the wrong entry
-- standing in their history and does nothing about the penalty or interest the
-- waterfall booked. There was no reversal in this schema at all (v1 said so
-- explicitly: "no un-approve flow"). There has to be one now.
--
-- HOW IT REVERSES. Not by recomputing. 036's settle_submission is told to record
-- what it actually allocated — base, penalty, interest, principal — on the
-- submission row, so a void subtracts the exact four numbers that were added.
-- Recomputing a penalty at void time would use today's date and quietly return a
-- different figure from the one that was banked.
--
-- WHAT IT REFUSES. A void is only safe while its effects are still the last thing
-- that happened. If the loan has since closed, been written off or restructured, or
-- another payment has landed on the same fee or loan, the re-pricing has moved on
-- and unwinding one payment underneath it would corrupt the schedule. In those
-- cases it refuses and says to use the 2-of-N savings or pool adjustment instead —
-- a correction that does not pretend to be a reversal.
--
-- THE IDENTITY HOLDS. v_pool_reconciliation asserts assets = claims. Every void
-- moves both sides: the negative earnings_ledger entry is what keeps retained
-- earnings in step with the penalty and interest coming back out of the pool.
--
-- Requires 036.

-- --------------------------------------------------------------------------
-- 1. Schema.
-- --------------------------------------------------------------------------

ALTER TABLE payment_submissions DROP CONSTRAINT IF EXISTS payment_submissions_status_check;
ALTER TABLE payment_submissions
  ADD CONSTRAINT payment_submissions_status_check
  CHECK (status IN ('pending', 'approved', 'rejected', 'voided'));

-- What the waterfall actually did with this payment. Written by settle_submission,
-- read by execute_payment_void. Also makes the allocation visible in the audit
-- trail for the first time — until now it could only be inferred by replaying the
-- waterfall by hand.
ALTER TABLE payment_submissions
  ADD COLUMN IF NOT EXISTS applied_base      numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS applied_penalty   numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS applied_interest  numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS applied_principal numeric(12,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN payment_submissions.applied_base IS
  'What settle_submission allocated (037). Zero on rows settled before this migration; those cannot be voided and must be corrected with a savings adjustment.';

CREATE TABLE IF NOT EXISTS payment_voids (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id uuid NOT NULL REFERENCES payment_submissions(id) ON DELETE CASCADE,
  reason        text NOT NULL,
  status        text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'approved', 'cancelled')),
  requested_by  uuid REFERENCES profiles(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  applied_at    timestamptz
);
CREATE INDEX IF NOT EXISTS payment_voids_status_idx ON payment_voids (status, created_at DESC);

CREATE TABLE IF NOT EXISTS payment_void_approvals (
  void_id     uuid NOT NULL REFERENCES payment_voids(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (void_id, admin_id)
);

ALTER TABLE payment_voids          ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_void_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read voids" ON payment_voids;
CREATE POLICY "Admins read voids" ON payment_voids FOR SELECT USING (is_admin());

DROP POLICY IF EXISTS "Admins read void approvals" ON payment_void_approvals;
CREATE POLICY "Admins read void approvals" ON payment_void_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON payment_voids, payment_void_approvals TO authenticated;

-- --------------------------------------------------------------------------
-- 2. settle_submission — same waterfall, now recording what it allocated.
--
--    Byte-for-byte the 036 body with four assignments added at the end of each
--    branch. Nothing about the arithmetic changes; 11_admin_recording's parity
--    assertions still hold.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION settle_submission(p_submission_id uuid, p_amount numeric)
RETURNS void AS $$
DECLARE
  s                 payment_submissions%ROWTYPE;
  v_left            numeric(12,2);
  v_penalty         numeric(12,2);
  v_pay             numeric(12,2);
  v_base            numeric(12,2);
  v_fee             monthly_fees%ROWTYPE;
  v_fee_remaining   numeric(12,2);
  v_inst            loan_installments%ROWTYPE;
  v_loan_id         uuid;
  v_int_remaining   numeric(12,2);
  v_prin_remaining  numeric(12,2);
  v_interest_pay    numeric(12,2);
  v_principal_pay   numeric(12,2);
  v_extra_principal numeric(12,2);
  v_outstanding     numeric(12,2);
  v_rate            numeric;
  v_new_int         numeric(12,2);
  v_last            int;
  v_interest_open   int;
BEGIN
  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Submission not found'; END IF;

  -- clock_timestamp(), not now(). now() is the TRANSACTION start time, so two
  -- payments settled in one transaction land on the identical reviewed_at and
  -- become unorderable — and "is this the most recent payment on this loan" is
  -- exactly the question a void has to answer before it is safe to apply.
  -- clock_timestamp() is also simply the truer value: when this settled.
  UPDATE payment_submissions
    SET status = 'approved', reviewed_at = clock_timestamp(), reviewed_by = auth.uid()
    WHERE id = p_submission_id;

  v_left := p_amount;

  -- ---------------------------------------------------------------- monthly fee
  IF s.submission_type = 'monthly_fee' THEN
    SELECT * INTO v_fee FROM monthly_fees WHERE id = s.related_id FOR UPDATE;
    IF v_fee.id IS NULL THEN RAISE EXCEPTION 'Monthly fee not found'; END IF;

    SELECT COALESCE(penalty_due, 0) INTO v_penalty
      FROM v_fee_status_money WHERE id = v_fee.id;
    v_fee_remaining := greatest(v_fee.amount - v_fee.amount_paid, 0);

    IF v_left > v_penalty + v_fee_remaining THEN
      RAISE EXCEPTION
        'Payment of % exceeds the % still owed on this fee (% base + % penalty). Record the exact amount and log any surplus as a savings deposit.',
        v_left, v_penalty + v_fee_remaining, v_fee_remaining, v_penalty;
    END IF;

    v_pay  := least(v_left, v_penalty);          -- penalty first
    v_left := v_left - v_pay;
    v_base := least(v_left, v_fee_remaining);

    UPDATE monthly_fees
       SET penalty_collected = penalty_collected + v_pay,
           amount_paid       = amount_paid + v_base,
           reviewed_by       = auth.uid()
     WHERE id = v_fee.id;

    UPDATE monthly_fees
       SET status  = CASE WHEN amount_paid >= amount THEN 'paid' ELSE 'partial' END,
           paid_at = CASE WHEN amount_paid >= amount THEN now() ELSE paid_at END
     WHERE id = v_fee.id;

    IF v_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'penalty', v_pay, p_submission_id, 'monthly_fee', v_fee.id);
    END IF;

    UPDATE payment_submissions
       SET applied_penalty = v_pay, applied_base = v_base
     WHERE id = p_submission_id;

  -- ----------------------------------------------------------- loan installment
  ELSIF s.submission_type = 'loan_installment' THEN
    SELECT * INTO v_inst FROM loan_installments WHERE id = s.related_id FOR UPDATE;
    IF v_inst.id IS NULL THEN RAISE EXCEPTION 'Installment not found'; END IF;
    v_loan_id := v_inst.loan_id;

    SELECT COALESCE(penalty_due, 0) INTO v_penalty
      FROM v_installment_status_money WHERE id = v_inst.id;

    v_int_remaining  := greatest(v_inst.interest_due  - v_inst.interest_paid,  0);
    v_prin_remaining := greatest(v_inst.principal_due - v_inst.principal_paid, 0);

    SELECT outstanding_principal, interest_rate INTO v_outstanding, v_rate
      FROM loans WHERE id = v_loan_id FOR UPDATE;

    IF v_left > v_penalty + v_int_remaining + v_outstanding THEN
      RAISE EXCEPTION
        'Payment of % exceeds everything outstanding on this loan (%). Record the exact amount and log any surplus as a savings deposit.',
        v_left, v_penalty + v_int_remaining + v_outstanding;
    END IF;

    v_pay  := least(v_left, v_penalty);               -- 1. penalty
    v_left := v_left - v_pay;

    v_interest_pay := least(v_left, v_int_remaining); -- 2. interest
    v_left := v_left - v_interest_pay;

    v_principal_pay := least(v_left, v_prin_remaining); -- 3. contracted principal
    v_left := v_left - v_principal_pay;

    -- 4. anything still left retires principal early
    v_extra_principal := least(v_left, greatest(v_outstanding - v_principal_pay, 0));

    UPDATE loan_installments
       SET penalty_collected = penalty_collected + v_pay,
           interest_paid     = interest_paid + v_interest_pay,
           principal_paid    = principal_paid + v_principal_pay + v_extra_principal,
           reviewed_by       = auth.uid()
     WHERE id = v_inst.id;

    UPDATE loan_installments
       SET status  = CASE
                       WHEN interest_paid >= interest_due AND principal_paid >= principal_due
                       THEN 'paid' ELSE 'partial'
                     END,
           paid_at = CASE
                       WHEN interest_paid >= interest_due AND principal_paid >= principal_due
                       THEN now() ELSE paid_at
                     END
     WHERE id = v_inst.id;

    v_outstanding := v_outstanding - v_principal_pay - v_extra_principal;
    UPDATE loans SET outstanding_principal = v_outstanding WHERE id = v_loan_id;

    IF v_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'penalty', v_pay, p_submission_id, 'loan_installment', v_inst.id);
    END IF;
    IF v_interest_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'interest', v_interest_pay, p_submission_id, 'loan_installment', v_inst.id);
    END IF;

    UPDATE payment_submissions
       SET applied_penalty   = v_pay,
           applied_interest  = v_interest_pay,
           applied_principal = v_principal_pay + v_extra_principal
     WHERE id = p_submission_id;

    SELECT count(*) INTO v_interest_open
      FROM loan_installments
     WHERE loan_id = v_loan_id
       AND status <> 'cancelled'
       AND interest_paid < interest_due;

    IF v_outstanding <= 0 AND v_interest_open = 0 THEN
      UPDATE loans SET status = 'closed' WHERE id = v_loan_id;
      UPDATE loan_installments
         SET status = 'cancelled'
       WHERE loan_id = v_loan_id AND status = 'pending';
    ELSE
      v_new_int := round(v_outstanding * COALESCE(v_rate, 0.05));
      SELECT max(installment_number) INTO v_last
        FROM loan_installments WHERE loan_id = v_loan_id AND status <> 'cancelled';

      UPDATE loan_installments
         SET interest_due  = v_new_int,
             principal_due = CASE WHEN installment_number = v_last THEN v_outstanding ELSE 0 END
       WHERE loan_id = v_loan_id
         AND status = 'pending';
    END IF;

  -- --------------------------------------------------------------------- savings
  ELSE
    UPDATE payment_submissions
       SET amount_claimed = p_amount, applied_base = p_amount
     WHERE id = p_submission_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION settle_submission(uuid, numeric) FROM PUBLIC, anon, authenticated;

-- --------------------------------------------------------------------------
-- 3. Can this row be voided at all?
--
--    Split out so the UI can grey out the button with the real reason instead of
--    letting an admin discover it at the end of a two-signature round trip.
--    Returns NULL when the void is safe, otherwise the reason it is not.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION payment_void_blocker(p_submission_id uuid)
RETURNS text AS $$
DECLARE
  s       payment_submissions%ROWTYPE;
  v_inst  loan_installments%ROWTYPE;
  v_loan  loans%ROWTYPE;
BEGIN
  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id;
  IF s.id IS NULL          THEN RETURN 'That payment does not exist.'; END IF;
  IF s.status = 'voided'   THEN RETURN 'That payment is already voided.'; END IF;
  IF s.status <> 'approved' THEN RETURN 'Only a settled payment can be voided.'; END IF;

  -- Rows settled before this migration have no allocation recorded, so there is
  -- nothing exact to reverse.
  IF s.applied_base + s.applied_penalty + s.applied_interest + s.applied_principal = 0 THEN
    RETURN 'This payment predates void support. Correct it with a savings adjustment.';
  END IF;

  -- Deliberately NOT checked here: whether a void request is already pending on
  -- this row. This function answers "is the reversal still safe to apply", and it
  -- is re-called by execute_payment_void at the moment of applying — where a
  -- pending void is the void being applied. The duplicate-request check belongs to
  -- request_payment_void, and lives there.

  -- Only the MOST RECENT settled payment is reversible, expressed as "is this that
  -- payment" rather than "does a later one exist". Same rule, but it cannot be
  -- fooled by two payments sharing a timestamp.
  IF s.submission_type = 'monthly_fee' THEN
    IF s.id <> (
      SELECT ps.id FROM payment_submissions ps
       WHERE ps.related_id = s.related_id
         AND ps.submission_type = 'monthly_fee'
         AND ps.status = 'approved'
       ORDER BY ps.reviewed_at DESC LIMIT 1
    ) THEN
      RETURN 'A later payment has already settled against this fee. Correct it with a savings adjustment.';
    END IF;

  ELSIF s.submission_type = 'loan_installment' THEN
    SELECT * INTO v_inst FROM loan_installments WHERE id = s.related_id;
    IF v_inst.id IS NULL THEN RETURN 'That installment no longer exists.'; END IF;

    SELECT * INTO v_loan FROM loans WHERE id = v_inst.loan_id;
    IF v_loan.status <> 'active' THEN
      RETURN 'This loan is no longer active, so the schedule cannot be unwound. Correct it with a savings adjustment.';
    END IF;

    -- Scoped to the whole LOAN, not just this installment: the waterfall re-prices
    -- every untouched installment off the outstanding balance, so a later payment
    -- anywhere on the loan has already moved what this one set.
    IF s.id <> (
      SELECT ps.id
        FROM payment_submissions ps
        JOIN loan_installments li ON li.id = ps.related_id
       WHERE ps.submission_type = 'loan_installment'
         AND li.loan_id = v_inst.loan_id
         AND ps.status = 'approved'
       ORDER BY ps.reviewed_at DESC LIMIT 1
    ) THEN
      RETURN 'A later repayment has landed on this loan. Correct it with a savings adjustment.';
    END IF;

    IF EXISTS (SELECT 1 FROM loan_actions
                WHERE loan_id = v_inst.loan_id AND status = 'approved'
                  AND applied_at > s.reviewed_at) THEN
      RETURN 'This loan has been restructured since. Correct it with a savings adjustment.';
    END IF;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 4. request / approve / cancel — 2-of-N, modelled on savings_adjustments (013).
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION request_payment_void(p_submission_id uuid, p_reason text)
RETURNS uuid AS $$
DECLARE
  v_id      uuid;
  v_blocker text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Say why this entry is being voided';
  END IF;

  v_blocker := payment_void_blocker(p_submission_id);
  IF v_blocker IS NOT NULL THEN RAISE EXCEPTION '%', v_blocker; END IF;

  IF EXISTS (SELECT 1 FROM payment_voids
              WHERE submission_id = p_submission_id AND status = 'pending') THEN
    RAISE EXCEPTION 'A void is already waiting for a second signature.';
  END IF;

  INSERT INTO payment_voids (submission_id, reason, requested_by)
  VALUES (p_submission_id, trim(p_reason), auth.uid())
  RETURNING id INTO v_id;

  INSERT INTO payment_void_approvals (void_id, admin_id) VALUES (v_id, auth.uid());

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_payment_void', 'submission', p_submission_id,
          jsonb_build_object('void_id', v_id, 'reason', trim(p_reason)));

  -- One admin is enough only in a group that has one admin, which is the same
  -- degradation every other 2-of-N flow has.
  IF (SELECT count(*) FROM payment_void_approvals WHERE void_id = v_id) >= required_approvals() THEN
    PERFORM execute_payment_void(v_id);
  ELSE
    INSERT INTO notifications (recipient_id, kind, title, body, data)
    SELECT p.id, 'void_awaiting_signature', 'A correction needs your signature', NULL,
           jsonb_build_object('void_id', v_id)
      FROM profiles p
     WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();
  END IF;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION approve_payment_void(p_void_id uuid)
RETURNS void AS $$
DECLARE
  v_void      payment_voids%ROWTYPE;
  v_approvals int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_void FROM payment_voids WHERE id = p_void_id FOR UPDATE;
  IF v_void.id IS NULL          THEN RAISE EXCEPTION 'Void request not found'; END IF;
  IF v_void.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';      END IF;

  BEGIN
    INSERT INTO payment_void_approvals (void_id, admin_id) VALUES (p_void_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this correction';
  END;

  SELECT count(*) INTO v_approvals FROM payment_void_approvals WHERE void_id = p_void_id;

  IF v_approvals >= required_approvals() THEN
    PERFORM execute_payment_void(p_void_id);
  ELSE
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_payment_void', 'submission', v_void.submission_id,
            jsonb_build_object('void_id', p_void_id, 'approvals', v_approvals));
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION cancel_payment_void(p_void_id uuid)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  UPDATE payment_voids SET status = 'cancelled'
   WHERE id = p_void_id AND status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'Void request not found or already processed'; END IF;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_payment_void', 'submission', NULL,
          jsonb_build_object('void_id', p_void_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. execute_payment_void — the reversal itself.
--
--    Private, and REVOKED in the same breath as its definition. The eight
--    functions 034 had to retrofit REVOKEs onto are the reason this line is here
--    and not in a later migration.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION execute_payment_void(p_void_id uuid)
RETURNS void AS $$
DECLARE
  v_void        payment_voids%ROWTYPE;
  s             payment_submissions%ROWTYPE;
  v_blocker     text;
  v_inst        loan_installments%ROWTYPE;
  v_loan_id     uuid;
  v_outstanding numeric(12,2);
  v_rate        numeric;
  v_new_int     numeric(12,2);
  v_last        int;
BEGIN
  SELECT * INTO v_void FROM payment_voids WHERE id = p_void_id FOR UPDATE;
  IF v_void.id IS NULL          THEN RAISE EXCEPTION 'Void request not found'; END IF;
  IF v_void.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';      END IF;

  -- Re-check at execution time, not just at request time: the second signature can
  -- arrive days later, by which point another payment may have landed.
  v_blocker := payment_void_blocker(v_void.submission_id);
  IF v_blocker IS NOT NULL THEN RAISE EXCEPTION '%', v_blocker; END IF;

  SELECT * INTO s FROM payment_submissions WHERE id = v_void.submission_id FOR UPDATE;

  IF s.submission_type = 'monthly_fee' THEN
    UPDATE monthly_fees
       SET amount_paid       = amount_paid - s.applied_base,
           penalty_collected = penalty_collected - s.applied_penalty
     WHERE id = s.related_id;

    UPDATE monthly_fees
       SET status  = CASE WHEN amount_paid >= amount THEN 'paid'
                          WHEN amount_paid > 0      THEN 'partial'
                          ELSE 'pending' END,
           paid_at = CASE WHEN amount_paid >= amount THEN paid_at ELSE NULL END
     WHERE id = s.related_id;

  ELSIF s.submission_type = 'loan_installment' THEN
    SELECT * INTO v_inst FROM loan_installments WHERE id = s.related_id FOR UPDATE;
    v_loan_id := v_inst.loan_id;

    UPDATE loan_installments
       SET penalty_collected = penalty_collected - s.applied_penalty,
           interest_paid     = interest_paid     - s.applied_interest,
           principal_paid    = principal_paid    - s.applied_principal
     WHERE id = v_inst.id;

    UPDATE loan_installments
       SET status  = CASE
                       WHEN interest_paid = 0 AND principal_paid = 0
                            AND penalty_collected = 0            THEN 'pending'
                       WHEN interest_paid >= interest_due
                            AND principal_paid >= principal_due  THEN 'paid'
                       ELSE 'partial'
                     END,
           paid_at = CASE
                       WHEN interest_paid >= interest_due
                            AND principal_paid >= principal_due  THEN paid_at
                       ELSE NULL
                     END
     WHERE id = v_inst.id;

    -- The principal goes back out on loan.
    UPDATE loans
       SET outstanding_principal = outstanding_principal + s.applied_principal
     WHERE id = v_loan_id
    RETURNING outstanding_principal, interest_rate INTO v_outstanding, v_rate;

    -- And the untouched installments are re-priced off the restored balance, by
    -- the same rule settle_submission uses, so the schedule matches what it would
    -- have been had the payment never happened.
    v_new_int := round(v_outstanding * COALESCE(v_rate, 0.05));
    SELECT max(installment_number) INTO v_last
      FROM loan_installments WHERE loan_id = v_loan_id AND status <> 'cancelled';

    UPDATE loan_installments
       SET interest_due  = v_new_int,
           principal_due = CASE WHEN installment_number = v_last THEN v_outstanding ELSE 0 END
     WHERE loan_id = v_loan_id AND status = 'pending';
  END IF;

  -- Penalty and interest booked by this payment come back out of retained
  -- earnings. Negative entries rather than deletes: the ledger is a dated record
  -- of what happened, and the mistake happened.
  IF s.applied_penalty > 0 THEN
    INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
    VALUES (s.member_id, 'penalty', -s.applied_penalty, s.id, 'void', p_void_id);
  END IF;
  IF s.applied_interest > 0 THEN
    INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
    VALUES (s.member_id, 'interest', -s.applied_interest, s.id, 'void', p_void_id);
  END IF;

  -- For a savings deposit this single flag is the whole reversal: both v_group_pool
  -- and v_pool_reconciliation count only status = 'approved'.
  UPDATE payment_submissions SET status = 'voided' WHERE id = s.id;

  UPDATE payment_voids SET status = 'approved', applied_at = now() WHERE id = p_void_id;

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (s.member_id, 'payment_voided', 'An entry was corrected',
          fmt_tzs(s.amount_claimed) || ' — ' || v_void.reason,
          jsonb_build_object('submission_id', s.id));

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'execute_payment_void', 'submission', s.id,
          jsonb_build_object(
            'void_id',           p_void_id,
            'member_id',         s.member_id,
            'submission_type',   s.submission_type,
            'amount',            s.amount_claimed,
            'applied_base',      s.applied_base,
            'applied_penalty',   s.applied_penalty,
            'applied_interest',  s.applied_interest,
            'applied_principal', s.applied_principal,
            'reason',            v_void.reason
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION execute_payment_void(uuid) FROM PUBLIC, anon, authenticated;

-- --------------------------------------------------------------------------
-- 6. Messages.
-- --------------------------------------------------------------------------

INSERT INTO notification_templates (kind, lang, title, body) VALUES
  ('void_awaiting_signature', 'sw', 'Marekebisho yanasubiri saini yako', NULL),
  ('void_awaiting_signature', 'en', 'A correction needs your signature', NULL),
  ('payment_voided', 'sw', 'Muamala umerekebishwa', NULL),
  ('payment_voided', 'en', 'An entry was corrected', NULL)
ON CONFLICT (kind, lang) DO UPDATE
  SET title = EXCLUDED.title, body = EXCLUDED.body;
