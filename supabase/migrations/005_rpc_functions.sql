-- 005_rpc_functions.sql — SECURITY DEFINER RPCs (build plan §8b, §8c, §8c-bis).
-- These hold the atomic multi-write logic; never replicate it client-side.

-- Loan approval + schedule generation. Called as
-- supabase.rpc('approve_loan', { p_loan_id, p_proof_url }) after the admin uploads
-- the disbursement screenshot. Atomic: loan update + 3 installment inserts.
CREATE OR REPLACE FUNCTION approve_loan(p_loan_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_loan loans%ROWTYPE;
  v_int  numeric(12,2);
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL          THEN RAISE EXCEPTION 'Loan not found';      END IF;
  IF v_loan.status <> 'pending' THEN RAISE EXCEPTION 'Loan is not pending'; END IF;

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
