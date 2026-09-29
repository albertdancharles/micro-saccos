-- 045_loan_cap_on_group_assets.sql — the 25% cap is a share of what the group
-- is WORTH, not of the cash that happens to be uncommitted today.
--
-- THE PROBLEM. `pool_loan_fraction` has been evaluated against v_group_pool
-- since 005. The pool is liquid cash: it already has every active loan's
-- principal subtracted. So the ceiling falls every time the group lends and
-- climbs back as borrowers repay, even though the group is no richer or poorer
-- at either moment — lending moves money from `pool` to `outstanding`, it does
-- not destroy any.
--
-- What that does to a meeting is the whole point. The group meets once a month
-- and agrees its loans in one sitting (030). Under the old rule the cap shrinks
-- as the meeting goes on, so the same 400,000 is allowed at the top of the
-- agenda and refused at the bottom:
--
--     assets 3,932,700 throughout          cap on pool     cap on assets
--     1st loan, pool 3,932,700                 983,175          983,175
--     11th loan, pool 1,200,000                300,000          983,175
--     13th loan, pool   400,000                100,000          983,175
--
-- Nobody voted for that. The rule the group states is "no one member may borrow
-- more than a quarter of the group", and the group is the pool PLUS what is out
-- on loan. Whose turn it is to be served should not change anyone's ceiling.
--
-- THE FIX. Evaluate the fraction against v_group_assets.total_assets_tzs
-- (012: pool + outstanding principal on active loans). That number does not
-- move when a loan is disbursed, so every member's ceiling is the same figure
-- all meeting, and it grows only when the group actually grows — new savings,
-- collected fees, earned interest.
--
-- THE NEW CHECK THAT COMES WITH IT. The old rule quietly guaranteed something
-- else: if a loan was at most a quarter of the POOL, the pool could obviously
-- cover it. Against assets that no longer holds — a group with 400,000 in cash
-- and 3,500,000 out on loan would happily approve 983,175 it cannot hand over,
-- and v_group_pool would go negative. So this migration adds the liquidity
-- check the old arithmetic made unnecessary: the pool must actually hold the
-- principal. It is not a new policy, it is the old guarantee written down.
--
-- The two checks now say different things, and the error messages keep them
-- apart: "more than a quarter of the group" is a rule about fairness, "the pool
-- holds only X" is a fact about cash.
--
-- NOT CHANGED. `contribution_multiplier` (the 5x arm), the value 0.25 itself,
-- and every other ceiling. The setting's LABEL changes, because it stopped
-- being true: it is a share of the group's assets now, not of the pool.
--
-- SCOPE. Newly approved loans only. Nothing recorded is restated — no existing
-- loan is re-checked against the new rule, and none would fail it anyway, since
-- assets >= pool always and the cap therefore only ever rises.
--
-- Requires 043 (current approve_loan), 012 (v_group_assets).

-- --------------------------------------------------------------------------
-- 1. The setting's label. The value and its bounds are untouched — only the
--    sentence describing what the fraction is a fraction OF.
-- --------------------------------------------------------------------------

UPDATE group_settings
   SET label = 'Max share of group assets per loan'
 WHERE key = 'pool_loan_fraction';

-- --------------------------------------------------------------------------
-- 2. approve_loan — 043's body, with cap 1 re-based and the liquidity check
--    added. Everything else (2-of-N tally, the admin mandate, the schedule,
--    meeting-day due dates, the audit row) is byte-for-byte 043.
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

  -- CHANGED (045): a share of everything the group owns, not of today's cash.
  -- total_assets_tzs does not move when a loan is disbursed, so the ceiling is
  -- the same for the first borrower of the meeting and the last.
  SELECT total_assets_tzs INTO v_assets FROM v_group_assets;
  IF v_loan.principal > floor(v_fraction * COALESCE(v_assets, 0)) THEN
    RAISE EXCEPTION 'Loan exceeds % of the group''s total assets (max %).',
      round(v_fraction * 100) || '%', floor(v_fraction * COALESCE(v_assets, 0));
  END IF;

  -- NEW (045): the cash has to be there. Against the pool this was implied;
  -- against assets it has to be said, or the group could approve money it has
  -- already lent to somebody else and drive v_group_pool negative.
  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;
  IF v_loan.principal > COALESCE(v_pool, 0) THEN
    RAISE EXCEPTION 'The pool holds only % — not enough to disburse % today. Wait for repayments.',
      COALESCE(v_pool, 0), v_loan.principal;
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
            -- 045: both figures, so the audit log shows which ceiling applied
            -- and what the cash position was at the moment of disbursement.
            'group_assets',  v_assets,
            'pool',          v_pool
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
