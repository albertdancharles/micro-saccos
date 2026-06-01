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
