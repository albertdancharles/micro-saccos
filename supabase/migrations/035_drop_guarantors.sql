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
