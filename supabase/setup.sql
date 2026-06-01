-- ============================================================================
-- setup.sql  —  Micro-SACCOS full hosted setup (migrations 001-005 concatenated)
-- ============================================================================
-- HOW TO USE (hosted, no Docker):
--   1. Create a project at https://supabase.com
--   2. Dashboard -> SQL Editor -> New query
--   3. Paste this ENTIRE file and click Run. Safe on a fresh project.
-- Then follow README.md "Hosted path" for env vars, seeding, and optional cron.
-- ============================================================================
-- ----------------------------------------------------------------------------
-- 001_create_tables.sql
-- ----------------------------------------------------------------------------

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


-- ----------------------------------------------------------------------------
-- 002_create_views.sql
-- ----------------------------------------------------------------------------

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


-- ----------------------------------------------------------------------------
-- 003_rls_policies.sql
-- ----------------------------------------------------------------------------

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


-- ----------------------------------------------------------------------------
-- 004_storage_bucket.sql
-- ----------------------------------------------------------------------------

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


-- ----------------------------------------------------------------------------
-- 005_rpc_functions.sql
-- ----------------------------------------------------------------------------

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


-- ----------------------------------------------------------------------------
-- 006_member_self_update.sql
-- ----------------------------------------------------------------------------

-- Let members update their own phone number from the Profile page without granting
-- blanket UPDATE on profiles. SECURITY DEFINER scopes the write to auth.uid()'s row.
CREATE OR REPLACE FUNCTION update_own_phone(p_phone text)
RETURNS void AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  UPDATE public.profiles
     SET phone_number = NULLIF(trim(p_phone), '')
   WHERE id = auth.uid();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;




-- ----------------------------------------------------------------------------
-- 007_audit_log.sql
-- ----------------------------------------------------------------------------

-- 007_audit_log.sql - every consequential admin/member action gets a row in
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


-- ----------------------------------------------------------------------------
-- 008_two_step_approvals.sql
-- ----------------------------------------------------------------------------
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


-- ----------------------------------------------------------------------------
-- 009_notifications.sql
-- ----------------------------------------------------------------------------
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


-- ----------------------------------------------------------------------------
-- 010_member_deletion.sql
-- ----------------------------------------------------------------------------
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
