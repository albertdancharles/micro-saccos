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
