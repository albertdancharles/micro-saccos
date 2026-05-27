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
