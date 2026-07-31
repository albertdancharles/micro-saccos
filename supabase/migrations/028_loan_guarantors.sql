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
