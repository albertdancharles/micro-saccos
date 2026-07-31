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
