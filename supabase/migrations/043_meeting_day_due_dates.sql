-- 043_meeting_day_due_dates.sql — an installment falls due on a meeting day.
--
-- THE BUG. The group meets on the LAST SATURDAY of each month, and that meeting
-- is the only occasion on which a member hands over a repayment. But every
-- approve_loan since 005 has set
--
--     due_date = today_eat() + n months
--
-- i.e. the same calendar day-of-month as the approval, which for a loan issued
-- at a meeting is the same day-of-month as some earlier meeting. Meeting dates
-- are not a fixed day of the month — the last Saturday walks between the 22nd
-- and the 28th — so roughly a third of the time the due date lands DAYS BEFORE
-- that month's meeting:
--
--     issued 2026-09-26 (meeting) -> inst 1 due 2026-10-26 -> meeting 2026-10-31
--     issued 2026-04-25 (meeting) -> inst 1 due 2026-05-25 -> meeting 2026-05-30
--
-- In those months v_installment_status flips the row to 'overdue' on the day
-- after the due date, and penalty_months jumps straight from 0 to 1 — so the
-- member is charged a FULL month of penalty (penalty_rate × total_due, 5% by
-- default) for four or five days in which the group had not yet met and there
-- was no way for them to pay. Over 24 months, 8 of them do this.
--
-- THE FIX. Anchor each installment to the meeting it will actually be paid at:
-- the last Saturday of the month it falls in. 'Overdue' then means what the
-- group means by it — you were at the meeting, or should have been, and did not
-- pay — instead of an artifact of which weekday the loan happened to be issued
-- on.
--
-- SCOPE. This changes NEWLY approved loans only. Installments already written
-- keep their dates; rewriting them would move real penalty amounts on balances
-- members have already seen, which is a decision for the group, not a migration.
-- See the note at the foot of this file for the backfill if the group votes it.
--
-- NOT TOUCHED: monthly fees. A fee is due on the last day of its own month
-- (014, 020) and the last Saturday always falls on or before that, so the
-- meeting is already the final collection before a fee turns overdue on the
-- 1st. Anchoring fees to the meeting day would make them STRICTER, turning a
-- fee overdue on the Sunday after the meeting — a rule change, not a bug fix.
--
-- Requires 041 (current approve_loan).

-- --------------------------------------------------------------------------
-- 1. The meeting day
--
--    The last Saturday of the month p_in falls in. Take the last day of that
--    month and step back to the most recent Saturday: EXTRACT(DOW) is 0 for
--    Sunday and 6 for Saturday, so (dow + 1) % 7 is the number of days back to
--    Saturday — 0 when the month already ends on one.
--
--    IMMUTABLE: depends only on its argument, so it can be indexed and folded
--    into constants.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION meeting_day(p_in date)
RETURNS date AS $$
  SELECT (d - ((EXTRACT(DOW FROM d)::int + 1) % 7))::date
  FROM (
    SELECT (date_trunc('month', p_in::timestamp)
            + INTERVAL '1 month' - INTERVAL '1 day')::date AS d
  ) s;
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION meeting_day(date) IS
  'The group''s meeting day for the month containing p_in: its last Saturday.';

GRANT EXECUTE ON FUNCTION meeting_day(date) TO authenticated;

-- --------------------------------------------------------------------------
-- 2. approve_loan — 041's body, with the one due_date expression changed.
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
      -- CHANGED (043): the meeting in the n-th month from now, not the same
      -- day-of-month. Adding months first keeps one installment per month even
      -- when the day clamps (Jan 31 + 1 month = Feb 28); meeting_day then moves
      -- it to that month's last Saturday.
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
            'months',        v_months
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 3. Backfill — NOT RUN. Here for the group to adopt deliberately.
--
--    Moving an existing due_date forward to its meeting day can only reduce a
--    penalty or leave it unchanged, never increase it, because meeting_day()
--    of a month is >= the 22nd and these dates cluster earlier. Even so it
--    rewrites what members were told they owe, so it belongs in
--    supabase/operations/ behind a vote, not in a migration that runs on deploy.
--
--    UPDATE loan_installments i
--       SET due_date = meeting_day(i.due_date)
--      FROM loans l
--     WHERE l.id = i.loan_id
--       AND l.status = 'active'
--       AND i.status NOT IN ('paid', 'cancelled')
--       AND i.due_date <> meeting_day(i.due_date);
-- --------------------------------------------------------------------------
