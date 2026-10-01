-- 047_contribution_counts_adjustments.sql — approve_loan measures a member's
-- contribution the way the rest of the system does.
--
-- THE PROBLEM. There are two definitions of a member's savings in this codebase
-- and they do not agree. The app — `getApprovedSavings` in src/lib/savings.js,
-- its admin-side twin in src/lib/admin.js, and group_member_directory() since
-- 021 — sums three things:
--
--     approved savings_deposit submissions
--   + monthly_fees.amount_paid across EVERY fee row
--   + approved savings_adjustments.delta
--
-- approve_loan sums two, and reads the fee term differently:
--
--     approved savings_deposit submissions
--   + monthly_fees.amount  on rows WHERE status = 'paid'
--
-- That text is unchanged from 005. 013 introduced savings_adjustments and 021
-- introduced partial fee payments; neither came back to approve_loan, and the six
-- rewrites since (020, 028, 035, 041, 043, 045) each copied the 005 wording
-- forward while changing the arms around it. So the gap is not a regression in
-- any one migration — it is a definition that never moved.
--
-- WHAT IT COST. On 2026-09-29 the group recorded its opening balances with
-- operations/2026-09-29_savings_opening_balance_230k.sql, which books them as
-- savings_adjustments rows on purpose: they are "a balance the group is
-- asserting, not a payment anybody submitted through the app". That is the one
-- table approve_loan does not read. A member holding 230,000 of savings, shown
-- 230,000 on their own dashboard and on the admin's approval card, was measured
-- by approve_loan at the 10,000 September fee alone — a ceiling of 70,000 where
-- the group's rule gives 1,610,000. Every loan the group agreed at the September
-- meeting is refused by the app with an arithmetic nobody voted for.
--
-- It errs the other way too, and that half matters just as much: a loan recovery
-- books a NEGATIVE adjustment (022), so savings clawed back to settle a default
-- were still counted toward the defaulter's next ceiling. And `amount` on rows
-- marked 'paid' drops a part-settled fee entirely, where the app counts the money
-- actually banked.
--
-- THE FIX. One definition, in one place. member_savings(uuid) is the three-term
-- sum, and approve_loan and group_member_directory() both call it, so the next
-- change to what savings means cannot land in one and miss the other. The value
-- group_member_directory returns is unchanged — same three terms, same rows; it
-- is the duplication that goes.
--
-- NOT CHANGED. `contribution_multiplier` (the 7x arm), the 25%-of-assets ceiling
-- and the liquidity check from 045, the 2-of-N tally, the admin mandate, the
-- schedule, the meeting-day due dates and the audit row — all byte-for-byte 045.
-- Only the two lines that computed v_contribution are replaced.
--
-- SCOPE. Newly approved loans only. Nothing recorded is restated, and no active
-- loan is re-checked. Every ceiling this moves, it moves UP for anyone holding a
-- positive adjustment and DOWN for anyone holding a negative one — which is the
-- point, and is exactly what the member has been shown all along.
--
-- Requires 045 (current approve_loan), 021 (group_member_directory,
-- monthly_fees.amount_paid), 013 (savings_adjustments).

-- --------------------------------------------------------------------------
-- 1. member_savings — the single definition. Mirrors lib/savings.js
--    getApprovedSavings term for term; that comment in 021 is now a contract
--    between three call sites rather than a note on one.
--
--    SECURITY DEFINER because both callers need to read a member's fees,
--    deposits and adjustments regardless of who is signed in — approve_loan is
--    an admin acting on someone else's loan. EXECUTE is revoked from the client
--    roles: nothing calls this from the browser, and both callers are themselves
--    SECURITY DEFINER, so they do not need the grant. The figure it returns is
--    not itself a secret — group_member_directory() has published every active
--    member's savings to every authenticated member since 019.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION member_savings(p_member_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
      COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                 WHERE member_id = p_member_id
                   AND submission_type = 'savings_deposit'
                   AND status = 'approved'), 0)
    -- amount_paid across every row, not `amount` on rows marked 'paid': since
    -- 021 a fee can be part-settled, and that money is savings already.
    + COALESCE((SELECT SUM(amount_paid) FROM monthly_fees
                 WHERE member_id = p_member_id), 0)
    -- 013. Positive for a correction or an asserted opening balance, negative
    -- for the clawback a loan recovery books (022).
    + COALESCE((SELECT SUM(delta) FROM savings_adjustments
                 WHERE target_member_id = p_member_id
                   AND status = 'approved'), 0);
$$;

REVOKE EXECUTE ON FUNCTION member_savings(uuid) FROM authenticated, anon;

-- --------------------------------------------------------------------------
-- 2. approve_loan — 045's body with the contribution SELECT replaced by the
--    call. Everything else is untouched.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_loan(p_loan_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_loan              loans%ROWTYPE;
  v_int               numeric(12,2);
  v_pool              numeric(14,2);
  v_assets            numeric(14,2);
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

  -- 045: a share of everything the group owns, not of today's cash.
  SELECT total_assets_tzs INTO v_assets FROM v_group_assets;
  IF v_loan.principal > floor(v_fraction * COALESCE(v_assets, 0)) THEN
    RAISE EXCEPTION 'Loan exceeds % of the group''s total assets (max %).',
      round(v_fraction * 100) || '%', floor(v_fraction * COALESCE(v_assets, 0));
  END IF;

  -- 045: the cash has to be there.
  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;
  IF v_loan.principal > COALESCE(v_pool, 0) THEN
    RAISE EXCEPTION 'The pool holds only % — not enough to disburse % today. Wait for repayments.',
      COALESCE(v_pool, 0), v_loan.principal;
  END IF;

  -- CHANGED (047): the same savings the member is shown, including approved
  -- adjustments and part-paid fees. Was two inline sums that had not moved
  -- since 005.
  v_contribution := member_savings(v_loan.member_id);
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
    -- OVERSEER: the superadmin is exempt from the loan-free-admin mandate.
    IF v_other_admin_loans >= v_total_admins - 1 AND NOT is_superadmin() THEN
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
      -- 043: the meeting in the n-th month from now, not the same day-of-month.
      meeting_day((today_eat() + (v_n || ' month')::interval)::date),
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
            'group_assets',  v_assets,
            'pool',          v_pool,
            -- 047: the figure the ceiling was actually measured against, so a
            -- later dispute does not have to reconstruct it from three tables.
            'contribution',  v_contribution
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 3. group_member_directory — same three terms, now via the shared function.
--    The returned value does not change; this removes the second copy so the
--    two cannot drift apart again.
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
    member_savings(p.id)                       AS savings_tzs,
    COALESCE(ln.outstanding, 0)                AS active_loan_tzs,
    ln.outstanding IS NOT NULL                 AS has_active_loan
  FROM profiles p
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
