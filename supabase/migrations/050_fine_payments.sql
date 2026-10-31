-- 050_fine_payments.sql — record a late or absence fine as money handed over.
--
-- THE RULE, the group's own: a fine goes straight into the group's money so it can be
-- lent to members, and it never adds to an individual's savings.
--
-- 030 already knows about fines, but only one way: "Apply the fines" on the meeting
-- register takes them out of the member's savings, and no cash moves. This is the other
-- way, for a member who hands the money over at the meeting. Cash arrives, so it adds to
-- the pool. That is the opposite of 030's "a fine moves ownership, not cash", and both
-- are right, because they describe different events.
--
-- WHERE THE MONEY GOES. Two types join payment_submissions, so a fine is keyed in the
-- same form, signed by the same rules and corrected by the same void as every other
-- payment:
--
--   pool      a new term in v_group_pool, which is what makes it lendable.
--   income    an earnings_ledger row, kind 'penalty', the same line 030's fines and
--             every late-fee penalty use. It reaches the income statement, the member
--             report and the cycle's share-out with no code that knows what a fine is.
--   savings   NOTHING. Everything that computes a member's savings, contribution or
--             loan ceiling filters on submission_type = 'savings_deposit', so these
--             rows are invisible to all of it. 23_fine_payments asserts that directly.
--
-- Assets and claims stay equal because the pool term and the ledger row rise together,
-- and a void takes both back: execute_payment_void (037) already reverses applied_penalty
-- and flips the status, so it needed no change.
--
-- WHO SIGNS. One admin for another member's fine, for 036's reason about fees: the
-- amount is the group's, not a judgement call. That reason holds only if the amount
-- really is the group's, so record_payment refuses anything above the fine the group has
-- set. Less is allowed, because what gets recorded is what actually arrived. An admin's
-- own fine still takes two signatures, and the overseer's one (041).
--
-- Requires 049.

-- --------------------------------------------------------------------------
-- 1. Schema.
-- --------------------------------------------------------------------------

ALTER TABLE payment_submissions
  DROP CONSTRAINT IF EXISTS payment_submissions_submission_type_check;
ALTER TABLE payment_submissions
  ADD CONSTRAINT payment_submissions_submission_type_check
  CHECK (submission_type IN ('savings_deposit', 'monthly_fee', 'loan_installment',
                             'fine_late', 'fine_absent'));

-- --------------------------------------------------------------------------
-- 2. settle_submission — 037's body with the one marked branch added.
--
--    The branch has to come before the final ELSE, which treats anything it does not
--    recognise as a savings deposit.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION settle_submission(p_submission_id uuid, p_amount numeric)
RETURNS void AS $$
DECLARE
  s                 payment_submissions%ROWTYPE;
  v_left            numeric(12,2);
  v_penalty         numeric(12,2);
  v_pay             numeric(12,2);
  v_base            numeric(12,2);
  v_fee             monthly_fees%ROWTYPE;
  v_fee_remaining   numeric(12,2);
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
  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Submission not found'; END IF;

  -- clock_timestamp(), not now(). now() is the TRANSACTION start time, so two
  -- payments settled in one transaction land on the identical reviewed_at and
  -- become unorderable — and "is this the most recent payment on this loan" is
  -- exactly the question a void has to answer before it is safe to apply.
  -- clock_timestamp() is also simply the truer value: when this settled.
  UPDATE payment_submissions
    SET status = 'approved', reviewed_at = clock_timestamp(), reviewed_by = auth.uid()
    WHERE id = p_submission_id;

  v_left := p_amount;

  -- ---------------------------------------------------------------- monthly fee
  IF s.submission_type = 'monthly_fee' THEN
    SELECT * INTO v_fee FROM monthly_fees WHERE id = s.related_id FOR UPDATE;
    IF v_fee.id IS NULL THEN RAISE EXCEPTION 'Monthly fee not found'; END IF;

    SELECT COALESCE(penalty_due, 0) INTO v_penalty
      FROM v_fee_status_money WHERE id = v_fee.id;
    v_fee_remaining := greatest(v_fee.amount - v_fee.amount_paid, 0);

    IF v_left > v_penalty + v_fee_remaining THEN
      RAISE EXCEPTION
        'Payment of % exceeds the % still owed on this fee (% base + % penalty). Record the exact amount and log any surplus as a savings deposit.',
        v_left, v_penalty + v_fee_remaining, v_fee_remaining, v_penalty;
    END IF;

    v_pay  := least(v_left, v_penalty);          -- penalty first
    v_left := v_left - v_pay;
    v_base := least(v_left, v_fee_remaining);

    UPDATE monthly_fees
       SET penalty_collected = penalty_collected + v_pay,
           amount_paid       = amount_paid + v_base,
           reviewed_by       = auth.uid()
     WHERE id = v_fee.id;

    UPDATE monthly_fees
       SET status  = CASE WHEN amount_paid >= amount THEN 'paid' ELSE 'partial' END,
           paid_at = CASE WHEN amount_paid >= amount THEN now() ELSE paid_at END
     WHERE id = v_fee.id;

    IF v_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'penalty', v_pay, p_submission_id, 'monthly_fee', v_fee.id);
    END IF;

    UPDATE payment_submissions
       SET applied_penalty = v_pay, applied_base = v_base
     WHERE id = p_submission_id;

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

    IF v_left > v_penalty + v_int_remaining + v_outstanding THEN
      RAISE EXCEPTION
        'Payment of % exceeds everything outstanding on this loan (%). Record the exact amount and log any surplus as a savings deposit.',
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

    IF v_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'penalty', v_pay, p_submission_id, 'loan_installment', v_inst.id);
    END IF;
    IF v_interest_pay > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
      VALUES (s.member_id, 'interest', v_interest_pay, p_submission_id, 'loan_installment', v_inst.id);
    END IF;

    UPDATE payment_submissions
       SET applied_penalty   = v_pay,
           applied_interest  = v_interest_pay,
           applied_principal = v_principal_pay + v_extra_principal
     WHERE id = p_submission_id;

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
      v_new_int := round(v_outstanding * COALESCE(v_rate, 0.05));
      SELECT max(installment_number) INTO v_last
        FROM loan_installments WHERE loan_id = v_loan_id AND status <> 'cancelled';

      UPDATE loan_installments
         SET interest_due  = v_new_int,
             principal_due = CASE WHEN installment_number = v_last THEN v_outstanding ELSE 0 END
       WHERE loan_id = v_loan_id
         AND status = 'pending';
    END IF;

  -- ------------------------------------------------------------------- fine (050)
  -- All of it is the group's income. Recorded as applied_penalty rather than
  -- applied_base because that is the column execute_payment_void reverses out of the
  -- earnings ledger; applied_base would leave the ledger row behind.
  ELSIF s.submission_type IN ('fine_late', 'fine_absent') THEN
    INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type)
    VALUES (s.member_id, 'penalty', p_amount, p_submission_id, s.submission_type);

    UPDATE payment_submissions
       SET amount_claimed = p_amount, applied_penalty = p_amount
     WHERE id = p_submission_id;

  -- --------------------------------------------------------------------- savings
  ELSE
    UPDATE payment_submissions
       SET amount_claimed = p_amount, applied_base = p_amount
     WHERE id = p_submission_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION settle_submission(uuid, numeric) FROM PUBLIC, anon, authenticated;

-- --------------------------------------------------------------------------
-- 3. v_group_pool — 030's view with the one marked term added.
--
--    Separate from the savings_deposit term above it on purpose: the two add the same
--    cash to the pool, and only the deposit gives a member a claim on it.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_group_pool AS
SELECT
    (SELECT COALESCE(SUM(amount_claimed), 0)
       FROM payment_submissions
       WHERE submission_type = 'savings_deposit' AND status = 'approved')
  -- 050: fines handed over in cash. The group's money, nobody's savings.
  + (SELECT COALESCE(SUM(amount_claimed), 0)
       FROM payment_submissions
       WHERE submission_type IN ('fine_late', 'fine_absent') AND status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM savings_adjustments WHERE status = 'approved')
  + (SELECT COALESCE(SUM(delta), 0)
       FROM pool_adjustments    WHERE status = 'approved')
  + (SELECT COALESCE(SUM(amount), 0)
       FROM loan_recoveries)
  -- Offsets the negative savings adjustment each fine writes.
  + (SELECT COALESCE(SUM(fine_tzs), 0)
       FROM meeting_attendance)
  + (SELECT COALESCE(SUM(amount_paid), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM monthly_fees)
  + (SELECT COALESCE(SUM(interest_paid), 0)
           + COALESCE(SUM(principal_paid), 0)
           + COALESCE(SUM(penalty_collected), 0)
       FROM loan_installments)
  - (SELECT COALESCE(SUM(principal), 0)
       FROM loans             WHERE status IN ('active', 'closed', 'written_off'))
  - (SELECT COALESCE(SUM(earnings_tzs), 0)
       FROM distributions     WHERE status = 'paid')
  AS pool_balance_tzs;

-- --------------------------------------------------------------------------
-- 4. submission_threshold — 041's body. A fine signs like a fee.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION submission_threshold(p_submission_id uuid)
RETURNS int AS $$
DECLARE
  s payment_submissions%ROWTYPE;
BEGIN
  IF is_superadmin() THEN RETURN 1; END IF;

  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id;
  IF s.id IS NULL THEN RETURN required_approvals(); END IF;

  IF s.recorded_by IS NOT NULL AND s.recorded_by = s.member_id THEN
    RETURN greatest(required_approvals(), 2);
  END IF;

  IF s.recorded_by IS NOT NULL
     AND s.submission_type IN ('monthly_fee', 'fine_late', 'fine_absent') THEN
    RETURN 1;
  END IF;

  RETURN required_approvals();
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. record_payment — 041's body, with the two types and the marked ceiling added.
--
--    The ceiling lives here and not in settle_submission because this is where the
--    figure is chosen. A later signature cannot change it (the first figure settles,
--    Decision #11), and a fine recorded just before the group votes a new amount was
--    still a correct fine.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION record_payment(
  p_member_id  uuid,
  p_type       text,
  p_related_id uuid,
  p_amount     numeric,
  p_proof_url  text DEFAULT NULL
)
RETURNS uuid AS $$
DECLARE
  v_id        uuid;
  v_self      boolean;
  v_admins    int;
  v_required  int;
  v_approvals int;
  v_fine      numeric;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Enter an amount greater than zero';
  END IF;
  IF p_type NOT IN ('savings_deposit', 'monthly_fee', 'loan_installment',
                    'fine_late', 'fine_absent') THEN
    RAISE EXCEPTION 'Unknown payment type: %', p_type;
  END IF;
  IF p_type IN ('monthly_fee', 'loan_installment') AND p_related_id IS NULL THEN
    RAISE EXCEPTION 'Choose which fee or installment this payment settles';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_member_id AND is_active = true) THEN
    RAISE EXCEPTION 'That member is not active';
  END IF;

  -- 050: on one signature, nothing else stands between a slipped zero and the pool.
  IF p_type IN ('fine_late', 'fine_absent') THEN
    v_fine := setting(CASE p_type WHEN 'fine_late' THEN 'attendance_fine_late'
                                  ELSE 'attendance_fine_absent' END);
    IF p_amount > v_fine THEN
      RAISE EXCEPTION 'This fine is %. Enter what actually arrived, up to that amount.',
        fmt_tzs(v_fine);
    END IF;
  END IF;

  v_self := (p_member_id = auth.uid());

  -- Fail here, not silently later. Without a second admin this row could never
  -- reach its threshold and would sit pending forever with no way to finish it.
  -- OVERSEER: exempt. Without this the overseer of a one-admin group could not
  -- record their own payment at all, since this guard precedes the threshold.
  IF v_self AND NOT is_superadmin() THEN
    SELECT count(*) INTO v_admins FROM profiles WHERE role = 'admin' AND is_active = true;
    IF v_admins < 2 THEN
      RAISE EXCEPTION 'A second admin is required to record your own payment. Promote another admin first.';
    END IF;
  END IF;

  INSERT INTO payment_submissions
    (member_id, submission_type, related_id, amount_claimed, proof_url, recorded_by)
  VALUES (p_member_id, p_type, p_related_id, p_amount, p_proof_url, auth.uid())
  RETURNING id INTO v_id;

  INSERT INTO submission_approvals (submission_id, admin_id, amount_received)
  VALUES (v_id, auth.uid(), p_amount);

  v_required := submission_threshold(v_id);
  SELECT count(*) INTO v_approvals FROM submission_approvals WHERE submission_id = v_id;

  IF v_approvals >= v_required THEN
    PERFORM settle_submission(v_id, p_amount);
  ELSE
    INSERT INTO notifications (recipient_id, kind, title, body, data)
    SELECT p.id, 'payment_awaiting_signature',
           'A payment needs your signature',
           NULL,
           jsonb_build_object('submission_id', v_id)
      FROM profiles p
     WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();
  END IF;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'record_payment', 'submission', v_id,
          jsonb_build_object(
            'submission_type', p_type,
            'member_id',       p_member_id,
            'amount',          p_amount,
            'self_recorded',   v_self,
            'approvals',       v_approvals,
            'required',        v_required,
            'settled',         v_approvals >= v_required
          ));

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 6. What the member is told — 049's body with the two labels added. The ELSE would
--    otherwise send them the column value: "Your fine_late was approved."
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION notify_on_submission_change()
RETURNS trigger AS $$
DECLARE
  v_type_label text;
BEGIN
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;
  -- 049: a batch sends one message per member, not one per row. A row rejected out
  -- of a batch says nothing either: the member was never told it was pending.
  IF NEW.settlement_batch_id IS NOT NULL THEN RETURN NEW; END IF;

  v_type_label := CASE NEW.submission_type
    WHEN 'savings_deposit'  THEN 'savings deposit'
    WHEN 'monthly_fee'      THEN 'monthly fee'
    WHEN 'loan_installment' THEN 'loan repayment'
    WHEN 'fine_late'        THEN 'late-arrival fine'
    WHEN 'fine_absent'      THEN 'missed-meeting fine'
    ELSE NEW.submission_type
  END;

  IF NEW.status = 'approved' THEN
    INSERT INTO notifications (recipient_id, kind, title, body, data)
    VALUES (NEW.member_id, 'submission_approved',
            'Payment approved',
            'Your ' || v_type_label || ' was approved.',
            jsonb_build_object('submission_id', NEW.id, 'amount', NEW.amount_claimed));
  ELSIF NEW.status = 'rejected' THEN
    INSERT INTO notifications (recipient_id, kind, title, body, data)
    VALUES (NEW.member_id, 'submission_rejected',
            'Payment rejected',
            COALESCE(NEW.rejection_reason, 'Your ' || v_type_label || ' was rejected.'),
            jsonb_build_object('submission_id', NEW.id));
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
