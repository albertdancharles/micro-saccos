-- 021_partial_payments.sql — accept the money members actually have.
--
-- Until now approve_submission refused anything below the full contracted amount:
--
--     IF v_final_amount < v_inst.total_due + v_penalty THEN
--       RAISE EXCEPTION 'Payment of % is below the required minimum %…'
--
-- So a member holding 60% of an installment could pay NOTHING, and a month later
-- was charged another 5% penalty on the whole amount. This migration replaces the
-- all-or-nothing rule with an allocation waterfall and a 'partial' status.
--
-- ALLOCATION WATERFALL (penalty first, principal last — the borrower's cheapest
-- debt is retired last, which is the standard order and stops a member from
-- servicing principal while a penalty compounds):
--
--   monthly fee        penalty → base
--   loan installment   penalty → interest → contracted principal → extra principal
--
-- A row becomes 'paid' only when nothing is left; otherwise 'partial'. Penalties
-- accrue on the REMAINING balance, so a member who has paid 80% is fined on the
-- 20% still owed, not on the original total.
--
-- Overpayment is never silently absorbed: on a loan it reduces principal early
-- (as before), and once there is genuinely nothing left to allocate to, the RPC
-- raises rather than booking the excess as a mystery "penalty". The admin logs the
-- surplus as a savings deposit instead.
--
-- v_group_pool CORRECTION (load-bearing). It summed `amount` / `total_due` for rows
-- WHERE status = 'paid'. With partial payments that would undercount cash on hand.
-- It now sums the actual paid columns across every row. This also fixes a
-- pre-existing bug: extra principal paid early (principal_paid above principal_due)
-- was never credited to the pool, because only total_due was counted.
--
-- Requires 020 (penalty_rate snapshots).

-- --------------------------------------------------------------------------
-- 1. Schema — how much of each obligation has actually been settled.
--    `penalty_collected` already exists on both tables and keeps its meaning
--    (cumulative penalty banked), so no separate penalty_paid column is added.
-- --------------------------------------------------------------------------

ALTER TABLE monthly_fees
  ADD COLUMN IF NOT EXISTS amount_paid numeric(12,2) NOT NULL DEFAULT 0;

ALTER TABLE loan_installments
  ADD COLUMN IF NOT EXISTS interest_paid numeric(12,2) NOT NULL DEFAULT 0;

-- Backfill: every row already marked 'paid' was, by the old all-or-nothing rule,
-- settled in full.
UPDATE monthly_fees      SET amount_paid   = amount       WHERE status = 'paid' AND amount_paid = 0;
UPDATE loan_installments SET interest_paid = interest_due WHERE status = 'paid' AND interest_paid = 0;
-- principal_paid was only populated from 011 onward; older paid rows settled their
-- contracted principal_due in full.
UPDATE loan_installments SET principal_paid = principal_due
 WHERE status = 'paid' AND principal_paid = 0 AND principal_due > 0;

ALTER TABLE monthly_fees DROP CONSTRAINT IF EXISTS monthly_fees_status_check;
ALTER TABLE monthly_fees
  ADD CONSTRAINT monthly_fees_status_check
  CHECK (status IN ('pending', 'partial', 'paid'));

ALTER TABLE loan_installments DROP CONSTRAINT IF EXISTS loan_installments_status_check;
ALTER TABLE loan_installments
  ADD CONSTRAINT loan_installments_status_check
  CHECK (status IN ('pending', 'partial', 'paid', 'cancelled'));

-- --------------------------------------------------------------------------
-- 2. Views — penalties accrue on what is STILL OWED, and every view exposes the
--    remaining balance so the UI can render "paid X of Y".
--
--    DROP + recreate (not CREATE OR REPLACE): the new columns land inside `mf.*` /
--    `li.*` and shift the output ordering, which CREATE OR REPLACE VIEW forbids.
-- --------------------------------------------------------------------------

DROP VIEW IF EXISTS v_fee_status_money;
DROP VIEW IF EXISTS v_fee_status CASCADE;

CREATE VIEW v_fee_status AS
WITH b AS (
  SELECT mf.*,
         (mf.period + INTERVAL '1 month' - INTERVAL '1 day')::date AS due_date,
         greatest(mf.amount - mf.amount_paid, 0)                   AS remaining
  FROM monthly_fees mf
)
SELECT
  b.*,
  CASE
    WHEN b.status = 'paid' OR b.remaining <= 0 OR today_eat() <= b.due_date THEN 0
    ELSE (date_part('year',  age(today_eat(), b.due_date)) * 12
        + date_part('month', age(today_eat(), b.due_date)))::int + 1
  END AS penalty_months,
  -- 'overdue' outranks 'partial': being past due is the signal that matters, and
  -- amount_paid > 0 tells the UI to render it as partly settled.
  CASE
    WHEN b.status = 'paid' OR b.remaining <= 0 THEN 'paid'
    WHEN today_eat() > b.due_date              THEN 'overdue'
    WHEN b.amount_paid > 0                     THEN 'partial'
    ELSE 'pending'
  END AS computed_status
FROM b;

-- total_with_penalty is now "what is still owed", not "the original amount plus a
-- penalty" — for an untouched fee the two are identical, so nothing changes for
-- rows nobody has paid into.
CREATE VIEW v_fee_status_money AS
SELECT
  f.*,
  round(f.penalty_rate * f.remaining * f.penalty_months)              AS penalty_due,
  f.remaining + round(f.penalty_rate * f.remaining * f.penalty_months) AS total_with_penalty
FROM v_fee_status f;

DROP VIEW IF EXISTS v_installment_status_money;
DROP VIEW IF EXISTS v_installment_status CASCADE;

CREATE VIEW v_installment_status AS
WITH b AS (
  SELECT li.*,
         greatest(li.interest_due  - li.interest_paid,  0) AS interest_remaining,
         -- principal_paid can exceed principal_due when a borrower repays early,
         -- so this is clamped at zero rather than going negative.
         greatest(li.principal_due - li.principal_paid, 0) AS principal_remaining
  FROM loan_installments li
)
SELECT
  b.*,
  (b.interest_remaining + b.principal_remaining) AS remaining,
  CASE
    WHEN b.status IN ('paid', 'cancelled')
      OR (b.interest_remaining + b.principal_remaining) <= 0
      OR today_eat() <= b.due_date THEN 0
    ELSE (date_part('year',  age(today_eat(), b.due_date)) * 12
        + date_part('month', age(today_eat(), b.due_date)))::int + 1
  END AS penalty_months,
  CASE
    WHEN b.status = 'cancelled' THEN 'cancelled'
    WHEN b.status = 'paid' OR (b.interest_remaining + b.principal_remaining) <= 0 THEN 'paid'
    WHEN today_eat() > b.due_date THEN 'overdue'
    WHEN (b.interest_paid + b.principal_paid) > 0 THEN 'partial'
    ELSE 'pending'
  END AS computed_status
FROM b;

CREATE VIEW v_installment_status_money AS
SELECT
  i.*,
  round(i.penalty_rate * i.remaining * i.penalty_months)               AS penalty_due,
  i.remaining + round(i.penalty_rate * i.remaining * i.penalty_months) AS total_with_penalty
FROM v_installment_status i;

GRANT SELECT ON v_fee_status, v_fee_status_money                 TO authenticated;
GRANT SELECT ON v_installment_status, v_installment_status_money TO authenticated;

-- --------------------------------------------------------------------------
-- 3. v_group_pool — count cash actually received, not contracted amounts.
--    Column structure is unchanged, so CREATE OR REPLACE is safe and
--    v_group_assets keeps working.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_group_pool AS
SELECT
    (SELECT COALESCE(SUM(amount_claimed), 0)
       FROM payment_submissions
       WHERE submission_type = 'savings_deposit' AND status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM savings_adjustments WHERE status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM pool_adjustments    WHERE status = 'approved')
  -- Every shilling banked against a fee, whether the fee is fully settled or not.
  + (SELECT COALESCE(SUM(amount_paid), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM monthly_fees)
  -- interest_paid + principal_paid captures early principal repayment, which the
  -- old SUM(total_due) silently dropped.
  + (SELECT COALESCE(SUM(interest_paid), 0)
           + COALESCE(SUM(principal_paid), 0)
           + COALESCE(SUM(penalty_collected), 0)
       FROM loan_installments)
  - (SELECT COALESCE(SUM(principal), 0)
       FROM loans             WHERE status IN ('active', 'closed'))
  AS pool_balance_tzs;

-- --------------------------------------------------------------------------
-- 4. group_member_directory — a member's savings must count partially-paid fees
--    too, or the transparency page under-reports everyone who is mid-payment.
--    (Mirrors lib/savings.js getApprovedSavings.)
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
    COALESCE(dep.total, 0) + COALESCE(fee.total, 0) + COALESCE(adj.total, 0) AS savings_tzs,
    COALESCE(ln.outstanding, 0)                                              AS active_loan_tzs,
    ln.outstanding IS NOT NULL                                               AS has_active_loan
  FROM profiles p
  LEFT JOIN LATERAL (
    SELECT SUM(amount_claimed) AS total
    FROM payment_submissions
    WHERE member_id = p.id
      AND submission_type = 'savings_deposit'
      AND status = 'approved'
  ) dep ON true
  LEFT JOIN LATERAL (
    SELECT SUM(amount_paid) AS total
    FROM monthly_fees
    WHERE member_id = p.id
  ) fee ON true
  LEFT JOIN LATERAL (
    SELECT SUM(delta) AS total
    FROM savings_adjustments
    WHERE target_member_id = p.id AND status = 'approved'
  ) adj ON true
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

-- --------------------------------------------------------------------------
-- 5. earnings_ledger — group income, recorded with a DATE as it is collected.
--
--    The pool tells you what the group holds; it cannot tell you what the group
--    EARNED, or when. Interest and penalties are the group's profit — the money a
--    share-out distributes — and they are indistinguishable from returned capital
--    once they land in the pool. Recording each one at the moment of collection is
--    what makes an end-of-cycle share-out possible (migration 024) without
--    reconstructing history from balances that have no timestamps.
--
--    Positive = income, negative = loss (a write-off, migration 022).
--    `submission_id` lets the capital calculation subtract the penalty portion of
--    a fee payment, leaving the part that is genuinely the member's savings.
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS earnings_ledger (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id     uuid REFERENCES profiles(id) ON DELETE SET NULL,
  kind          text NOT NULL CHECK (kind IN ('interest', 'penalty', 'write_off')),
  amount        numeric(14,2) NOT NULL,
  submission_id uuid REFERENCES payment_submissions(id) ON DELETE SET NULL,
  source_type   text,
  source_id     uuid,
  occurred_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS earnings_ledger_occurred_idx ON earnings_ledger (occurred_at);
CREATE INDEX IF NOT EXISTS earnings_ledger_submission_idx ON earnings_ledger (submission_id);

ALTER TABLE earnings_ledger ENABLE ROW LEVEL SECURITY;

-- Group income is group business: every member can see what the group earned.
-- (Consistent with the transparency directory in 019.)
DROP POLICY IF EXISTS "Everyone reads earnings" ON earnings_ledger;
CREATE POLICY "Everyone reads earnings" ON earnings_ledger
  FOR SELECT USING (auth.uid() IS NOT NULL);

GRANT SELECT ON earnings_ledger TO authenticated;

-- --------------------------------------------------------------------------
-- 6. approve_submission — the allocation waterfall.
--
--    2-of-N is unchanged: the FIRST approver's amount_received is the one that
--    gets allocated when the threshold is reached.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_submission(p_submission_id uuid, p_amount_received numeric)
RETURNS void AS $$
DECLARE
  s                 payment_submissions%ROWTYPE;
  v_required        int;
  v_approvals       int;
  v_final_amount    numeric(12,2);
  v_left            numeric(12,2);
  v_penalty         numeric(12,2);
  v_pay             numeric(12,2);
  -- fee
  v_fee             monthly_fees%ROWTYPE;
  v_fee_remaining   numeric(12,2);
  -- installment
  v_inst            loan_installments%ROWTYPE;
  v_loan_id         uuid;
  v_int_remaining   numeric(12,2);
  v_prin_remaining  numeric(12,2);
  v_interest_pay    numeric(12,2);
  v_principal_pay   numeric(12,2);
  v_extra_principal numeric(12,2);
  v_outstanding     numeric(12,2);
  v_rate            numeric;
  v_new_int         numeric(12,2);
  v_last            int;
  v_interest_open   int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_amount_received IS NULL OR p_amount_received <= 0 THEN
    RAISE EXCEPTION 'Invalid amount received';
  END IF;

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

  SELECT amount_received INTO v_final_amount
  FROM submission_approvals
  WHERE submission_id = p_submission_id
  ORDER BY approved_at ASC
  LIMIT 1;

  UPDATE payment_submissions
    SET status = 'approved', reviewed_at = now(), reviewed_by = auth.uid()
    WHERE id = p_submission_id;

  v_left := v_final_amount;

  -- ---------------------------------------------------------------- monthly fee
  IF s.submission_type = 'monthly_fee' THEN
    SELECT * INTO v_fee FROM monthly_fees WHERE id = s.related_id FOR UPDATE;
    IF v_fee.id IS NULL THEN RAISE EXCEPTION 'Monthly fee not found'; END IF;

    SELECT COALESCE(penalty_due, 0) INTO v_penalty
      FROM v_fee_status_money WHERE id = v_fee.id;
    v_fee_remaining := greatest(v_fee.amount - v_fee.amount_paid, 0);

    IF v_left > v_penalty + v_fee_remaining THEN
      RAISE EXCEPTION
        'Payment of % exceeds the % still owed on this fee (% base + % penalty). Approve the exact amount and log any surplus as a savings deposit.',
        v_left, v_penalty + v_fee_remaining, v_fee_remaining, v_penalty;
    END IF;

    v_pay  := least(v_left, v_penalty);          -- penalty first
    v_left := v_left - v_pay;
    UPDATE monthly_fees
       SET penalty_collected = penalty_collected + v_pay,
           amount_paid       = amount_paid + least(v_left, v_fee_remaining),
           reviewed_by       = auth.uid()
     WHERE id = v_fee.id;

    UPDATE monthly_fees
       SET status  = CASE WHEN amount_paid >= amount THEN 'paid' ELSE 'partial' END,
           paid_at = CASE WHEN amount_paid >= amount THEN now() ELSE paid_at END
     WHERE id = v_fee.id;

    -- The penalty is group income; the base is the member's own capital.
    IF v_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'penalty', v_pay, p_submission_id, 'monthly_fee', v_fee.id);
    END IF;

  -- ----------------------------------------------------------- loan installment
  ELSIF s.submission_type = 'loan_installment' THEN
    SELECT * INTO v_inst FROM loan_installments WHERE id = s.related_id FOR UPDATE;
    IF v_inst.id IS NULL THEN RAISE EXCEPTION 'Installment not found'; END IF;
    v_loan_id := v_inst.loan_id;

    SELECT COALESCE(penalty_due, 0) INTO v_penalty
      FROM v_installment_status_money WHERE id = v_inst.id;

    v_int_remaining  := greatest(v_inst.interest_due  - v_inst.interest_paid,  0);
    v_prin_remaining := greatest(v_inst.principal_due - v_inst.principal_paid, 0);

    SELECT outstanding_principal, interest_rate INTO v_outstanding, v_rate
      FROM loans WHERE id = v_loan_id FOR UPDATE;

    -- Ceiling on what this payment can possibly settle: the penalty, the interest
    -- still owed on this installment, and every shilling of principal still out.
    IF v_left > v_penalty + v_int_remaining + v_outstanding THEN
      RAISE EXCEPTION
        'Payment of % exceeds everything outstanding on this loan (%). Approve the exact amount and log any surplus as a savings deposit.',
        v_left, v_penalty + v_int_remaining + v_outstanding;
    END IF;

    v_pay  := least(v_left, v_penalty);               -- 1. penalty
    v_left := v_left - v_pay;

    v_interest_pay := least(v_left, v_int_remaining); -- 2. interest
    v_left := v_left - v_interest_pay;

    v_principal_pay := least(v_left, v_prin_remaining); -- 3. contracted principal
    v_left := v_left - v_principal_pay;

    -- 4. anything still left retires principal early
    v_extra_principal := least(v_left, greatest(v_outstanding - v_principal_pay, 0));

    UPDATE loan_installments
       SET penalty_collected = penalty_collected + v_pay,
           interest_paid     = interest_paid + v_interest_pay,
           principal_paid    = principal_paid + v_principal_pay + v_extra_principal,
           reviewed_by       = auth.uid()
     WHERE id = v_inst.id;

    UPDATE loan_installments
       SET status  = CASE
                       WHEN interest_paid >= interest_due AND principal_paid >= principal_due
                       THEN 'paid' ELSE 'partial'
                     END,
           paid_at = CASE
                       WHEN interest_paid >= interest_due AND principal_paid >= principal_due
                       THEN now() ELSE paid_at
                     END
     WHERE id = v_inst.id;

    v_outstanding := v_outstanding - v_principal_pay - v_extra_principal;
    UPDATE loans SET outstanding_principal = v_outstanding WHERE id = v_loan_id;

    -- Interest and penalty are the group's earnings on this loan; principal is the
    -- group's own money coming back and is NOT income.
    IF v_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'penalty', v_pay, p_submission_id, 'loan_installment', v_inst.id);
    END IF;
    IF v_interest_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'interest', v_interest_pay, p_submission_id, 'loan_installment', v_inst.id);
    END IF;

    -- Is any interest still owed anywhere on this loan? The waterfall pays interest
    -- before principal, so this is normally 0 by the time principal clears — the
    -- check is here so an underpaid loan can never close with interest outstanding.
    SELECT count(*) INTO v_interest_open
      FROM loan_installments
     WHERE loan_id = v_loan_id
       AND status <> 'cancelled'
       AND interest_paid < interest_due;

    IF v_outstanding <= 0 AND v_interest_open = 0 THEN
      UPDATE loans SET status = 'closed' WHERE id = v_loan_id;
      UPDATE loan_installments
         SET status = 'cancelled'
       WHERE loan_id = v_loan_id AND status = 'pending';
    ELSE
      -- Re-price the UNTOUCHED installments against the new outstanding balance.
      -- 'partial' rows are deliberately excluded: restating the interest on a row
      -- someone has already part-paid would rewrite an agreed figure.
      v_new_int := round(v_outstanding * COALESCE(v_rate, 0.05));
      SELECT max(installment_number) INTO v_last
        FROM loan_installments WHERE loan_id = v_loan_id AND status <> 'cancelled';

      UPDATE loan_installments
         SET interest_due  = v_new_int,
             principal_due = CASE WHEN installment_number = v_last THEN v_outstanding ELSE 0 END
       WHERE loan_id = v_loan_id
         AND status = 'pending';
    END IF;

  -- --------------------------------------------------------------------- savings
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
