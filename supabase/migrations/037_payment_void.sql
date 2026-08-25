-- 037_payment_void.sql — undoing an admin's typo.
--
-- Until 036 a wrong figure was a member's wrong figure: they uploaded a screenshot,
-- an admin read it, and if the two disagreed the admin rejected it and the member
-- filed again. Nothing was ever posted by mistake because nothing was posted
-- without being read off a proof.
--
-- Now the admin keys the amount from an M-Pesa SMS, so a mistyped 50,000 for 5,000
-- posts, settles, moves the pool and closes a fee. The old answer — the 2-of-N
-- savings adjustment — patches the member's balance but leaves the wrong entry
-- standing in their history and does nothing about the penalty or interest the
-- waterfall booked. There was no reversal in this schema at all (v1 said so
-- explicitly: "no un-approve flow"). There has to be one now.
--
-- HOW IT REVERSES. Not by recomputing. 036's settle_submission is told to record
-- what it actually allocated — base, penalty, interest, principal — on the
-- submission row, so a void subtracts the exact four numbers that were added.
-- Recomputing a penalty at void time would use today's date and quietly return a
-- different figure from the one that was banked.
--
-- WHAT IT REFUSES. A void is only safe while its effects are still the last thing
-- that happened. If the loan has since closed, been written off or restructured, or
-- another payment has landed on the same fee or loan, the re-pricing has moved on
-- and unwinding one payment underneath it would corrupt the schedule. In those
-- cases it refuses and says to use the 2-of-N savings or pool adjustment instead —
-- a correction that does not pretend to be a reversal.
--
-- THE IDENTITY HOLDS. v_pool_reconciliation asserts assets = claims. Every void
-- moves both sides: the negative earnings_ledger entry is what keeps retained
-- earnings in step with the penalty and interest coming back out of the pool.
--
-- Requires 036.

-- --------------------------------------------------------------------------
-- 1. Schema.
-- --------------------------------------------------------------------------

ALTER TABLE payment_submissions DROP CONSTRAINT IF EXISTS payment_submissions_status_check;
ALTER TABLE payment_submissions
  ADD CONSTRAINT payment_submissions_status_check
  CHECK (status IN ('pending', 'approved', 'rejected', 'voided'));

-- What the waterfall actually did with this payment. Written by settle_submission,
-- read by execute_payment_void. Also makes the allocation visible in the audit
-- trail for the first time — until now it could only be inferred by replaying the
-- waterfall by hand.
ALTER TABLE payment_submissions
  ADD COLUMN IF NOT EXISTS applied_base      numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS applied_penalty   numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS applied_interest  numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS applied_principal numeric(12,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN payment_submissions.applied_base IS
  'What settle_submission allocated (037). Zero on rows settled before this migration; those cannot be voided and must be corrected with a savings adjustment.';

CREATE TABLE IF NOT EXISTS payment_voids (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id uuid NOT NULL REFERENCES payment_submissions(id) ON DELETE CASCADE,
  reason        text NOT NULL,
  status        text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'approved', 'cancelled')),
  requested_by  uuid REFERENCES profiles(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  applied_at    timestamptz
);
CREATE INDEX IF NOT EXISTS payment_voids_status_idx ON payment_voids (status, created_at DESC);

CREATE TABLE IF NOT EXISTS payment_void_approvals (
  void_id     uuid NOT NULL REFERENCES payment_voids(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (void_id, admin_id)
);

ALTER TABLE payment_voids          ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_void_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read voids" ON payment_voids;
CREATE POLICY "Admins read voids" ON payment_voids FOR SELECT USING (is_admin());

DROP POLICY IF EXISTS "Admins read void approvals" ON payment_void_approvals;
CREATE POLICY "Admins read void approvals" ON payment_void_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON payment_voids, payment_void_approvals TO authenticated;

-- --------------------------------------------------------------------------
-- 2. settle_submission — same waterfall, now recording what it allocated.
--
--    Byte-for-byte the 036 body with four assignments added at the end of each
--    branch. Nothing about the arithmetic changes; 11_admin_recording's parity
--    assertions still hold.
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
-- 3. Can this row be voided at all?
--
--    Split out so the UI can grey out the button with the real reason instead of
--    letting an admin discover it at the end of a two-signature round trip.
--    Returns NULL when the void is safe, otherwise the reason it is not.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION payment_void_blocker(p_submission_id uuid)
RETURNS text AS $$
DECLARE
  s       payment_submissions%ROWTYPE;
  v_inst  loan_installments%ROWTYPE;
  v_loan  loans%ROWTYPE;
BEGIN
  SELECT * INTO s FROM payment_submissions WHERE id = p_submission_id;
  IF s.id IS NULL          THEN RETURN 'That payment does not exist.'; END IF;
  IF s.status = 'voided'   THEN RETURN 'That payment is already voided.'; END IF;
  IF s.status <> 'approved' THEN RETURN 'Only a settled payment can be voided.'; END IF;

  -- Rows settled before this migration have no allocation recorded, so there is
  -- nothing exact to reverse.
  IF s.applied_base + s.applied_penalty + s.applied_interest + s.applied_principal = 0 THEN
    RETURN 'This payment predates void support. Correct it with a savings adjustment.';
  END IF;

  -- Deliberately NOT checked here: whether a void request is already pending on
  -- this row. This function answers "is the reversal still safe to apply", and it
  -- is re-called by execute_payment_void at the moment of applying — where a
  -- pending void is the void being applied. The duplicate-request check belongs to
  -- request_payment_void, and lives there.

  -- Only the MOST RECENT settled payment is reversible, expressed as "is this that
  -- payment" rather than "does a later one exist". Same rule, but it cannot be
  -- fooled by two payments sharing a timestamp.
  IF s.submission_type = 'monthly_fee' THEN
    IF s.id <> (
      SELECT ps.id FROM payment_submissions ps
       WHERE ps.related_id = s.related_id
         AND ps.submission_type = 'monthly_fee'
         AND ps.status = 'approved'
       ORDER BY ps.reviewed_at DESC LIMIT 1
    ) THEN
      RETURN 'A later payment has already settled against this fee. Correct it with a savings adjustment.';
    END IF;

  ELSIF s.submission_type = 'loan_installment' THEN
    SELECT * INTO v_inst FROM loan_installments WHERE id = s.related_id;
    IF v_inst.id IS NULL THEN RETURN 'That installment no longer exists.'; END IF;

    SELECT * INTO v_loan FROM loans WHERE id = v_inst.loan_id;
    IF v_loan.status <> 'active' THEN
      RETURN 'This loan is no longer active, so the schedule cannot be unwound. Correct it with a savings adjustment.';
    END IF;

    -- Scoped to the whole LOAN, not just this installment: the waterfall re-prices
    -- every untouched installment off the outstanding balance, so a later payment
    -- anywhere on the loan has already moved what this one set.
    IF s.id <> (
      SELECT ps.id
        FROM payment_submissions ps
        JOIN loan_installments li ON li.id = ps.related_id
       WHERE ps.submission_type = 'loan_installment'
         AND li.loan_id = v_inst.loan_id
         AND ps.status = 'approved'
       ORDER BY ps.reviewed_at DESC LIMIT 1
    ) THEN
      RETURN 'A later repayment has landed on this loan. Correct it with a savings adjustment.';
    END IF;

    IF EXISTS (SELECT 1 FROM loan_actions
                WHERE loan_id = v_inst.loan_id AND status = 'approved'
                  AND applied_at > s.reviewed_at) THEN
      RETURN 'This loan has been restructured since. Correct it with a savings adjustment.';
    END IF;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 4. request / approve / cancel — 2-of-N, modelled on savings_adjustments (013).
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION request_payment_void(p_submission_id uuid, p_reason text)
RETURNS uuid AS $$
DECLARE
  v_id      uuid;
  v_blocker text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Say why this entry is being voided';
  END IF;

  v_blocker := payment_void_blocker(p_submission_id);
  IF v_blocker IS NOT NULL THEN RAISE EXCEPTION '%', v_blocker; END IF;

  IF EXISTS (SELECT 1 FROM payment_voids
              WHERE submission_id = p_submission_id AND status = 'pending') THEN
    RAISE EXCEPTION 'A void is already waiting for a second signature.';
  END IF;

  INSERT INTO payment_voids (submission_id, reason, requested_by)
  VALUES (p_submission_id, trim(p_reason), auth.uid())
  RETURNING id INTO v_id;

  INSERT INTO payment_void_approvals (void_id, admin_id) VALUES (v_id, auth.uid());

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_payment_void', 'submission', p_submission_id,
          jsonb_build_object('void_id', v_id, 'reason', trim(p_reason)));

  -- One admin is enough only in a group that has one admin, which is the same
  -- degradation every other 2-of-N flow has.
  IF (SELECT count(*) FROM payment_void_approvals WHERE void_id = v_id) >= required_approvals() THEN
    PERFORM execute_payment_void(v_id);
  ELSE
    INSERT INTO notifications (recipient_id, kind, title, body, data)
    SELECT p.id, 'void_awaiting_signature', 'A correction needs your signature', NULL,
           jsonb_build_object('void_id', v_id)
      FROM profiles p
     WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();
  END IF;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION approve_payment_void(p_void_id uuid)
RETURNS void AS $$
DECLARE
  v_void      payment_voids%ROWTYPE;
  v_approvals int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_void FROM payment_voids WHERE id = p_void_id FOR UPDATE;
  IF v_void.id IS NULL          THEN RAISE EXCEPTION 'Void request not found'; END IF;
  IF v_void.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';      END IF;

  BEGIN
    INSERT INTO payment_void_approvals (void_id, admin_id) VALUES (p_void_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this correction';
  END;

  SELECT count(*) INTO v_approvals FROM payment_void_approvals WHERE void_id = p_void_id;

  IF v_approvals >= required_approvals() THEN
    PERFORM execute_payment_void(p_void_id);
  ELSE
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_payment_void', 'submission', v_void.submission_id,
            jsonb_build_object('void_id', p_void_id, 'approvals', v_approvals));
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION cancel_payment_void(p_void_id uuid)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  UPDATE payment_voids SET status = 'cancelled'
   WHERE id = p_void_id AND status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'Void request not found or already processed'; END IF;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_payment_void', 'submission', NULL,
          jsonb_build_object('void_id', p_void_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. execute_payment_void — the reversal itself.
--
--    Private, and REVOKED in the same breath as its definition. The eight
--    functions 034 had to retrofit REVOKEs onto are the reason this line is here
--    and not in a later migration.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION execute_payment_void(p_void_id uuid)
RETURNS void AS $$
DECLARE
  v_void        payment_voids%ROWTYPE;
  s             payment_submissions%ROWTYPE;
  v_blocker     text;
  v_inst        loan_installments%ROWTYPE;
  v_loan_id     uuid;
  v_outstanding numeric(12,2);
  v_rate        numeric;
  v_new_int     numeric(12,2);
  v_last        int;
BEGIN
  SELECT * INTO v_void FROM payment_voids WHERE id = p_void_id FOR UPDATE;
  IF v_void.id IS NULL          THEN RAISE EXCEPTION 'Void request not found'; END IF;
  IF v_void.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';      END IF;

  -- Re-check at execution time, not just at request time: the second signature can
  -- arrive days later, by which point another payment may have landed.
  v_blocker := payment_void_blocker(v_void.submission_id);
  IF v_blocker IS NOT NULL THEN RAISE EXCEPTION '%', v_blocker; END IF;

  SELECT * INTO s FROM payment_submissions WHERE id = v_void.submission_id FOR UPDATE;

  IF s.submission_type = 'monthly_fee' THEN
    UPDATE monthly_fees
       SET amount_paid       = amount_paid - s.applied_base,
           penalty_collected = penalty_collected - s.applied_penalty
     WHERE id = s.related_id;

    UPDATE monthly_fees
       SET status  = CASE WHEN amount_paid >= amount THEN 'paid'
                          WHEN amount_paid > 0      THEN 'partial'
                          ELSE 'pending' END,
           paid_at = CASE WHEN amount_paid >= amount THEN paid_at ELSE NULL END
     WHERE id = s.related_id;

  ELSIF s.submission_type = 'loan_installment' THEN
    SELECT * INTO v_inst FROM loan_installments WHERE id = s.related_id FOR UPDATE;
    v_loan_id := v_inst.loan_id;

    UPDATE loan_installments
       SET penalty_collected = penalty_collected - s.applied_penalty,
           interest_paid     = interest_paid     - s.applied_interest,
           principal_paid    = principal_paid    - s.applied_principal
     WHERE id = v_inst.id;

    UPDATE loan_installments
       SET status  = CASE
                       WHEN interest_paid = 0 AND principal_paid = 0
                            AND penalty_collected = 0            THEN 'pending'
                       WHEN interest_paid >= interest_due
                            AND principal_paid >= principal_due  THEN 'paid'
                       ELSE 'partial'
                     END,
           paid_at = CASE
                       WHEN interest_paid >= interest_due
                            AND principal_paid >= principal_due  THEN paid_at
                       ELSE NULL
                     END
     WHERE id = v_inst.id;

    -- The principal goes back out on loan.
    UPDATE loans
       SET outstanding_principal = outstanding_principal + s.applied_principal
     WHERE id = v_loan_id
    RETURNING outstanding_principal, interest_rate INTO v_outstanding, v_rate;

    -- And the untouched installments are re-priced off the restored balance, by
    -- the same rule settle_submission uses, so the schedule matches what it would
    -- have been had the payment never happened.
    v_new_int := round(v_outstanding * COALESCE(v_rate, 0.05));
    SELECT max(installment_number) INTO v_last
      FROM loan_installments WHERE loan_id = v_loan_id AND status <> 'cancelled';

    UPDATE loan_installments
       SET interest_due  = v_new_int,
           principal_due = CASE WHEN installment_number = v_last THEN v_outstanding ELSE 0 END
     WHERE loan_id = v_loan_id AND status = 'pending';
  END IF;

  -- Penalty and interest booked by this payment come back out of retained
  -- earnings. Negative entries rather than deletes: the ledger is a dated record
  -- of what happened, and the mistake happened.
  IF s.applied_penalty > 0 THEN
    INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
    VALUES (s.member_id, 'penalty', -s.applied_penalty, s.id, 'void', p_void_id);
  END IF;
  IF s.applied_interest > 0 THEN
    INSERT INTO earnings_ledger (member_id, kind, amount, submission_id, source_type, source_id)
    VALUES (s.member_id, 'interest', -s.applied_interest, s.id, 'void', p_void_id);
  END IF;

  -- For a savings deposit this single flag is the whole reversal: both v_group_pool
  -- and v_pool_reconciliation count only status = 'approved'.
  UPDATE payment_submissions SET status = 'voided' WHERE id = s.id;

  UPDATE payment_voids SET status = 'approved', applied_at = now() WHERE id = p_void_id;

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (s.member_id, 'payment_voided', 'An entry was corrected',
          fmt_tzs(s.amount_claimed) || ' — ' || v_void.reason,
          jsonb_build_object('submission_id', s.id));

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'execute_payment_void', 'submission', s.id,
          jsonb_build_object(
            'void_id',           p_void_id,
            'member_id',         s.member_id,
            'submission_type',   s.submission_type,
            'amount',            s.amount_claimed,
            'applied_base',      s.applied_base,
            'applied_penalty',   s.applied_penalty,
            'applied_interest',  s.applied_interest,
            'applied_principal', s.applied_principal,
            'reason',            v_void.reason
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION execute_payment_void(uuid) FROM PUBLIC, anon, authenticated;

-- --------------------------------------------------------------------------
-- 6. Messages.
-- --------------------------------------------------------------------------

INSERT INTO notification_templates (kind, lang, title, body) VALUES
  ('void_awaiting_signature', 'sw', 'Marekebisho yanasubiri saini yako', NULL),
  ('void_awaiting_signature', 'en', 'A correction needs your signature', NULL),
  ('payment_voided', 'sw', 'Muamala umerekebishwa', NULL),
  ('payment_voided', 'en', 'An entry was corrected', NULL)
ON CONFLICT (kind, lang) DO UPDATE
  SET title = EXCLUDED.title, body = EXCLUDED.body;
