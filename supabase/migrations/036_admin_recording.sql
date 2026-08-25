-- 036_admin_recording.sql — admins key every transaction.
--
-- 034 removed the member's ability to file. This puts the intake back on the admin
-- side, without reimplementing a single line of the money logic.
--
-- THE ONE IDEA HERE: `approve_submission` was two things welded together — a 2-of-N
-- signature tally, and the settlement waterfall (penalty -> interest -> principal,
-- fee part-payment, early-principal retirement, loan closing, re-pricing the
-- remaining installments, the earnings ledger). Only the first half is about who
-- may act. This migration splits the second half out as `settle_submission()` and
-- has all three intake paths call it, so there is exactly one implementation of the
-- waterfall in the schema and the new paths cannot drift from the tested one.
--
-- WHO SIGNS WHAT (the group's decisions, not defaults):
--   monthly fee, another member      -> ONE admin. It is a fixed, predictable
--                                      amount; batching 15 of them behind a second
--                                      signature every month is friction with no
--                                      information in it.
--   savings deposit, loan repayment  -> TWO admins. The amount varies, so a second
--                                      pair of eyes is worth the delay.
--   an admin's OWN money, any type   -> TWO admins, always. The recorder cannot be
--                                      the only signature on their own account.
--
-- Requires 035.

-- --------------------------------------------------------------------------
-- 1. Schema: an admin-keyed row is not a member-uploaded proof.
--
--    proof_url was NOT NULL because the row's whole purpose was to carry a
--    screenshot a member had uploaded. An admin recording from the M-Pesa SMS on
--    their own phone often has nothing to attach, and inventing a placeholder
--    string to satisfy a constraint would put junk in the audit trail.
--
--    recorded_by keeps the two eras distinguishable forever: NULL means a member
--    filed it themselves, before this release.
-- --------------------------------------------------------------------------

ALTER TABLE payment_submissions ALTER COLUMN proof_url DROP NOT NULL;
ALTER TABLE payment_submissions
  ADD COLUMN IF NOT EXISTS recorded_by uuid REFERENCES profiles(id);

COMMENT ON COLUMN payment_submissions.recorded_by IS
  'The admin who keyed this entry (036). NULL for rows a member filed themselves, which is every row created before the admin mandate.';

-- --------------------------------------------------------------------------
-- 2. settle_submission — the waterfall, lifted verbatim out of approve_submission.
--
--    Body is byte-for-byte the settlement half of the 021 version: same ordering,
--    same ceilings, same earnings_ledger entries, same loan-closing and re-pricing
--    rules. What is NOT here is the authorization check, the signature tally and
--    the audit row — those belong to the caller, which is the point of the split.
--
--    Private. It moves money with no permission check of its own, so it must never
--    be reachable from PostgREST. This is exactly the shape of the eight functions
--    034 had to revoke; the REVOKE ships in the same breath as the definition this
--    time, and names anon/authenticated as well as PUBLIC because Supabase's
--    default privileges grant to those roles explicitly.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION settle_submission(p_submission_id uuid, p_amount numeric)
RETURNS void AS $$
DECLARE
  s                 payment_submissions%ROWTYPE;
  v_left            numeric(12,2);
  v_penalty         numeric(12,2);
  v_pay             numeric(12,2);
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

  UPDATE payment_submissions
    SET status = 'approved', reviewed_at = now(), reviewed_by = auth.uid()
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
    UPDATE monthly_fees
       SET penalty_collected = penalty_collected + v_pay,
           amount_paid       = amount_paid + least(v_left, v_fee_remaining),
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

  -- --------------------------------------------------------------------- savings
  ELSE
    UPDATE payment_submissions SET amount_claimed = p_amount
      WHERE id = p_submission_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION settle_submission(uuid, numeric) FROM PUBLIC, anon, authenticated;

-- --------------------------------------------------------------------------
-- 3. approve_submission — now just the tally, delegating the money.
--
--    Identical behaviour to the 021 version. The self-approval block stays: it is
--    what stops the admin who recorded their own payment from also being its
--    second signature.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_submission(p_submission_id uuid, p_amount_received numeric)
RETURNS void AS $$
DECLARE
  s              payment_submissions%ROWTYPE;
  v_required     int;
  v_approvals    int;
  v_final_amount numeric(12,2);
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

  v_required := submission_threshold(p_submission_id);
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

  -- The first signature's figure is the one that settles (Decision #11).
  SELECT amount_received INTO v_final_amount
  FROM submission_approvals
  WHERE submission_id = p_submission_id
  ORDER BY approved_at ASC
  LIMIT 1;

  PERFORM settle_submission(p_submission_id, v_final_amount);

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_submission', 'submission', p_submission_id,
          jsonb_build_object(
            'submission_type', s.submission_type,
            'member_id',       s.member_id,
            'amount_received', v_final_amount,
            'approvals',       v_approvals
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 4. How many signatures does THIS submission need?
--
--    required_approvals() answers for the group (least(2, active admins)). This
--    answers for one row, because the group decided the threshold varies by what
--    is being recorded — and because an admin's own money is never a one-signature
--    matter regardless of how few admins there are.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION submission_threshold(p_submission_id uuid)
RETURNS int AS $$
DECLARE
  s payment_submissions%ROWTYPE;
BEGIN
  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id;
  IF s.id IS NULL THEN RETURN required_approvals(); END IF;

  -- An admin's own money: two signatures, always. greatest(...,2) rather than
  -- required_approvals() so a one-admin group cannot degrade this to a single
  -- signature the way every other flow does.
  IF s.recorded_by IS NOT NULL AND s.recorded_by = s.member_id THEN
    RETURN greatest(required_approvals(), 2);
  END IF;

  -- A monthly fee recorded by an admin for someone else: one signature. Fixed
  -- amount, fixed due date, nothing to second-guess.
  IF s.recorded_by IS NOT NULL AND s.submission_type = 'monthly_fee' THEN
    RETURN 1;
  END IF;

  RETURN required_approvals();
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. record_payment — one entry, any type.
--
--    Creates the row AND casts the recording admin's signature in one call, then
--    settles if that already meets the row's threshold. A second admin, when one is
--    needed, completes it through the ordinary approve_submission queue.
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
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Enter an amount greater than zero';
  END IF;
  IF p_type NOT IN ('savings_deposit', 'monthly_fee', 'loan_installment') THEN
    RAISE EXCEPTION 'Unknown payment type: %', p_type;
  END IF;
  IF p_type IN ('monthly_fee', 'loan_installment') AND p_related_id IS NULL THEN
    RAISE EXCEPTION 'Choose which fee or installment this payment settles';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_member_id AND is_active = true) THEN
    RAISE EXCEPTION 'That member is not active';
  END IF;

  v_self := (p_member_id = auth.uid());

  -- Fail here, not silently later. Without a second admin this row could never
  -- reach its threshold and would sit pending forever with no way to finish it.
  IF v_self THEN
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
-- 6. record_fee_payments — the monthly batch.
--
--    One call posts the whole sheet. Fees are the predictable half of the month's
--    work: ~15 identical amounts against rows the system generated itself, so
--    keying them one at a time behind a second signature is friction with no
--    information in it.
--
--    Entries are `[{"fee_id": uuid, "amount": numeric, "proof_url": text}]`.
--    The member is derived from the fee rather than passed, so a mistyped member
--    cannot be paired with someone else's fee.
--
--    All-or-nothing: one bad entry raises and the whole batch rolls back, so the
--    admin never has to work out which half of a sheet posted.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION record_fee_payments(p_entries jsonb)
RETURNS int AS $$
DECLARE
  v_entry    jsonb;
  v_fee      monthly_fees%ROWTYPE;
  v_amount   numeric(12,2);
  v_sub_id   uuid;
  v_count    int := 0;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_entries IS NULL OR jsonb_typeof(p_entries) <> 'array' THEN
    RAISE EXCEPTION 'Expected an array of fee payments';
  END IF;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_entries) LOOP
    SELECT * INTO v_fee FROM monthly_fees
     WHERE id = (v_entry->>'fee_id')::uuid FOR UPDATE;
    IF v_fee.id IS NULL THEN
      RAISE EXCEPTION 'Monthly fee % not found', v_entry->>'fee_id';
    END IF;

    v_amount := (v_entry->>'amount')::numeric;
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RAISE EXCEPTION 'Enter an amount greater than zero for every member you have ticked';
    END IF;

    -- An admin's own fee is never a one-signature matter. Send it to
    -- record_payment, which collects the second signature properly.
    IF v_fee.member_id = auth.uid() THEN
      RAISE EXCEPTION 'Record your own fee separately — it needs a second admin''s signature.';
    END IF;

    INSERT INTO payment_submissions
      (member_id, submission_type, related_id, amount_claimed, proof_url, recorded_by)
    VALUES (v_fee.member_id, 'monthly_fee', v_fee.id, v_amount,
            NULLIF(v_entry->>'proof_url', ''), auth.uid())
    RETURNING id INTO v_sub_id;

    INSERT INTO submission_approvals (submission_id, admin_id, amount_received)
    VALUES (v_sub_id, auth.uid(), v_amount);

    PERFORM settle_submission(v_sub_id, v_amount);
    v_count := v_count + 1;
  END LOOP;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'record_fee_payments', 'submission', NULL,
          jsonb_build_object('entries', v_count));

  RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 7. file_loan — the admin raises the request the member used to.
--
--    approve_loan (035) still does the disbursing, still needs 2-of-N, still
--    applies both ceilings. This only creates the pending row.
--
--    The one-open-loan rule (Decision #4) is enforced HERE, in SQL, for the first
--    time. It has only ever lived in the client (`submitLoanRequest`), with a
--    comment on the loans table admitting as much — so it was never a rule, just a
--    disabled button. Now that there is exactly one way in, it can be real.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION file_loan(p_member_id uuid, p_principal numeric)
RETURNS uuid AS $$
DECLARE
  v_id   uuid;
  v_name text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_principal IS NULL OR p_principal <= 0 THEN
    RAISE EXCEPTION 'Enter a loan amount greater than zero';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_member_id AND is_active = true) THEN
    RAISE EXCEPTION 'That member is not active';
  END IF;
  IF EXISTS (SELECT 1 FROM loans
              WHERE member_id = p_member_id AND status IN ('pending', 'active')) THEN
    RAISE EXCEPTION 'That member already has a loan in progress';
  END IF;

  INSERT INTO loans (member_id, principal, status)
  VALUES (p_member_id, p_principal, 'pending')
  RETURNING id INTO v_id;

  SELECT full_name INTO v_name FROM profiles WHERE id = p_member_id;

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'loan_filed', 'A loan is waiting for approval',
         COALESCE(v_name, 'A member') || ' — ' || fmt_tzs(p_principal),
         jsonb_build_object('loan_id', v_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'file_loan', 'loan', v_id,
          jsonb_build_object('member_id', p_member_id, 'principal', p_principal));

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 8. Withdrawals move to the admin side.
--
--    Same validation as 025's request_withdrawal, including the member_withdrawable
--    ceiling; only the caller changes. approve_withdrawal (2-of-N) and
--    mark_withdrawal_paid are untouched.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin_request_withdrawal(
  p_member_id uuid, p_amount numeric, p_reason text
)
RETURNS uuid AS $$
DECLARE
  v_id   uuid;
  v_max  numeric(14,2);
  v_name text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_member_id AND is_active = true) THEN
    RAISE EXCEPTION 'That member is not active';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Enter an amount greater than zero';
  END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every withdrawal';
  END IF;
  IF EXISTS (SELECT 1 FROM withdrawal_requests
              WHERE member_id = p_member_id AND status IN ('pending', 'approved')) THEN
    RAISE EXCEPTION 'That member already has a withdrawal in progress';
  END IF;

  SELECT withdrawable_tzs INTO v_max FROM member_withdrawable(p_member_id);
  IF p_amount > v_max THEN
    RAISE EXCEPTION 'They can withdraw at most % right now', v_max;
  END IF;

  INSERT INTO withdrawal_requests (member_id, amount, reason)
  VALUES (p_member_id, p_amount, trim(p_reason))
  RETURNING id INTO v_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'admin_request_withdrawal', 'withdrawal', v_id,
          jsonb_build_object('member_id', p_member_id, 'amount', p_amount, 'reason', p_reason));

  SELECT full_name INTO v_name FROM profiles WHERE id = p_member_id;
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'withdrawal_requested', 'Withdrawal requested',
         COALESCE(v_name, 'A member') || ' — ' || fmt_tzs(p_amount),
         jsonb_build_object('request_id', v_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- The member-facing entry point is gone.
DROP FUNCTION IF EXISTS request_withdrawal(numeric, text);

-- --------------------------------------------------------------------------
-- 9. Messages for the two new notification kinds.
-- --------------------------------------------------------------------------

INSERT INTO notification_templates (kind, lang, title, body) VALUES
  ('payment_awaiting_signature', 'sw', 'Malipo yanasubiri saini yako', NULL),
  ('payment_awaiting_signature', 'en', 'A payment needs your signature', NULL),
  ('loan_filed', 'sw', 'Mkopo unasubiri idhini', NULL),
  ('loan_filed', 'en', 'A loan is waiting for approval', NULL)
ON CONFLICT (kind, lang) DO UPDATE
  SET title = EXCLUDED.title, body = EXCLUDED.body;
