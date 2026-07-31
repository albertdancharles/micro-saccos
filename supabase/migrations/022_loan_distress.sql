-- 022_loan_distress.sql — what happens when a loan goes bad.
--
-- Before this migration `loans.status` was (pending, active, closed, rejected). A
-- borrower who could not repay simply accrued 5% a month forever: there was no way
-- to reschedule, to write the debt off, or to settle it against the savings they
-- already hold in the pool. Three admin actions, each 2-of-N, fill that gap:
--
--   restructure  — cancel the untouched installments and re-cut the schedule over a
--                  new term against the CURRENT outstanding principal.
--   write off    — recognise the loss: outstanding → 0, loan closed as written_off,
--                  the pool permanently absorbs the principal.
--   recover from — settle part or all of the debt against the borrower's own
--   savings       savings, which are already sitting in the pool.
--
-- NOT ADDED: a manual 'defaulted' status. A status an admin has to remember to set
-- drifts out of sync with reality the moment someone forgets. `v_loan_risk` below
-- derives non-performance from the installment record instead, so it is always
-- current and needs no maintenance.
--
-- RESTRUCTURING FORGIVES ACCRUED PENALTY on the installments it cancels — cancelled
-- rows stop accruing (021's views return penalty_months = 0 for them). That is a
-- real decision, which is why it takes two admin signatures and lands in audit_log.
--
-- Requires 020 (interest_rate snapshot) and 021 (partial payments).

-- --------------------------------------------------------------------------
-- 1. Schema
-- --------------------------------------------------------------------------

ALTER TABLE loans DROP CONSTRAINT IF EXISTS loans_status_check;
ALTER TABLE loans
  ADD CONSTRAINT loans_status_check
  CHECK (status IN ('pending', 'active', 'closed', 'rejected', 'written_off'));

-- A restructure appends installments after the existing ones, so a loan that is
-- rescheduled more than once can pass 12. The UNIQUE (loan_id, installment_number)
-- constraint is what actually keeps them distinct.
ALTER TABLE loan_installments DROP CONSTRAINT IF EXISTS loan_installments_installment_number_check;
ALTER TABLE loan_installments
  ADD CONSTRAINT loan_installments_installment_number_check
  CHECK (installment_number > 0);

-- One table for all three actions, mirroring pool_adjustments (015).
CREATE TABLE IF NOT EXISTS loan_actions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_id      uuid NOT NULL REFERENCES loans(id) ON DELETE CASCADE,
  action       text NOT NULL CHECK (action IN ('restructure', 'write_off', 'recover_from_savings')),
  amount       numeric(12,2),   -- recover_from_savings only
  term_months  int,             -- restructure only
  reason       text NOT NULL,
  requested_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
  status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'cancelled')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  applied_at   timestamptz
);
CREATE INDEX IF NOT EXISTS loan_actions_status_idx ON loan_actions (status, created_at DESC);

CREATE TABLE IF NOT EXISTS loan_action_approvals (
  action_id   uuid NOT NULL REFERENCES loan_actions(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (action_id, admin_id)
);

-- Recoveries are booked against the pool to cancel out the negative savings
-- adjustment they create. No cash moves when a debt is settled from savings: the
-- member's claim on the pool shrinks and the receivable shrinks with it, so the
-- pool's CASH balance must stay exactly where it was. Without this offset the
-- savings adjustment alone would double-count the loss.
CREATE TABLE IF NOT EXISTS loan_recoveries (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_id     uuid NOT NULL REFERENCES loans(id) ON DELETE CASCADE,
  member_id   uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  amount      numeric(12,2) NOT NULL CHECK (amount > 0),
  action_id   uuid REFERENCES loan_actions(id) ON DELETE SET NULL,
  recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS loan_recoveries_loan_idx ON loan_recoveries (loan_id);

ALTER TABLE loan_actions          ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_action_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_recoveries       ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read loan actions" ON loan_actions;
CREATE POLICY "Admins read loan actions" ON loan_actions
  FOR SELECT USING (is_admin());

-- A borrower can see what is being proposed about their own loan.
DROP POLICY IF EXISTS "Borrower reads own loan actions" ON loan_actions;
CREATE POLICY "Borrower reads own loan actions" ON loan_actions
  FOR SELECT USING (loan_id IN (SELECT id FROM loans WHERE member_id = auth.uid()));

DROP POLICY IF EXISTS "Admins read loan action approvals" ON loan_action_approvals;
CREATE POLICY "Admins read loan action approvals" ON loan_action_approvals
  FOR SELECT USING (is_admin());

DROP POLICY IF EXISTS "Read own or all recoveries" ON loan_recoveries;
CREATE POLICY "Read own or all recoveries" ON loan_recoveries
  FOR SELECT USING (member_id = auth.uid() OR is_admin());

GRANT SELECT ON loan_actions, loan_action_approvals, loan_recoveries TO authenticated;

-- --------------------------------------------------------------------------
-- 2. v_group_pool — recognise written-off principal and recovery offsets.
--
--   * 'written_off' joins ('active','closed') in the principal subtraction: the
--     money left the pool and is never coming back.
--   * loan_recoveries add back the cash the negative savings_adjustments row
--     removes, because settling a debt from savings moves no actual cash.
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
  + (SELECT COALESCE(SUM(amount), 0)
       FROM loan_recoveries)
  + (SELECT COALESCE(SUM(amount_paid), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM monthly_fees)
  + (SELECT COALESCE(SUM(interest_paid), 0)
           + COALESCE(SUM(principal_paid), 0)
           + COALESCE(SUM(penalty_collected), 0)
       FROM loan_installments)
  - (SELECT COALESCE(SUM(principal), 0)
       FROM loans             WHERE status IN ('active', 'closed', 'written_off'))
  AS pool_balance_tzs;

-- --------------------------------------------------------------------------
-- 3. v_loan_risk — non-performance derived from the record, never hand-set.
--    security_invoker so it inherits the loans/installments RLS: a member sees
--    only their own loan here, an admin sees every one.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_loan_risk
WITH (security_invoker = true) AS
SELECT
  l.id                        AS loan_id,
  l.member_id,
  l.principal,
  l.outstanding_principal,
  count(i.id)                 AS overdue_installments,
  min(i.due_date)             AS oldest_overdue,
  (today_eat() - min(i.due_date))::int AS days_overdue,
  COALESCE(SUM(i.penalty_due), 0)      AS penalty_accrued
FROM loans l
JOIN v_installment_status_money i ON i.loan_id = l.id
WHERE l.status = 'active'
  AND i.computed_status = 'overdue'
GROUP BY l.id, l.member_id, l.principal, l.outstanding_principal
HAVING count(i.id) >= 2;

GRANT SELECT ON v_loan_risk TO authenticated;

-- --------------------------------------------------------------------------
-- 4. Execution — runs only once the approval threshold is met.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION execute_loan_action(p_action_id uuid)
RETURNS void AS $$
DECLARE
  v_act         loan_actions%ROWTYPE;
  v_loan        loans%ROWTYPE;
  v_outstanding numeric(12,2);
  v_rate        numeric;
  v_int         numeric(12,2);
  v_next        int;
  v_n           int;
  v_amount      numeric(12,2);
  v_savings     numeric(14,2);
  v_title       text;
  v_body        text;
BEGIN
  SELECT * INTO v_act FROM loan_actions WHERE id = p_action_id FOR UPDATE;
  IF v_act.id IS NULL          THEN RAISE EXCEPTION 'Loan action not found'; END IF;
  IF v_act.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';     END IF;

  SELECT * INTO v_loan FROM loans WHERE id = v_act.loan_id FOR UPDATE;
  IF v_loan.id IS NULL          THEN RAISE EXCEPTION 'Loan not found';           END IF;
  IF v_loan.status <> 'active'  THEN RAISE EXCEPTION 'Loan is no longer active'; END IF;

  v_outstanding := v_loan.outstanding_principal;
  v_rate        := COALESCE(v_loan.interest_rate, 0.05);

  -- ------------------------------------------------------------- restructure
  IF v_act.action = 'restructure' THEN
    -- Untouched installments are cancelled (this is what stops the penalty clock);
    -- 'partial' rows are left alone so a member's part-payment is never erased.
    UPDATE loan_installments
       SET status = 'cancelled'
     WHERE loan_id = v_loan.id AND status = 'pending';

    SELECT COALESCE(max(installment_number), 0) INTO v_next
      FROM loan_installments WHERE loan_id = v_loan.id;

    v_int := round(v_outstanding * v_rate);
    FOR v_n IN 1..v_act.term_months LOOP
      INSERT INTO loan_installments
        (loan_id, installment_number, due_date, principal_due, interest_due, penalty_rate)
      VALUES (
        v_loan.id,
        v_next + v_n,
        (today_eat() + (v_n || ' month')::interval)::date,
        CASE WHEN v_n = v_act.term_months THEN v_outstanding ELSE 0 END,
        v_int,
        setting('penalty_rate')
      );
    END LOOP;

    v_title := 'Loan rescheduled';
    v_body  := 'Your loan has been rescheduled over ' || v_act.term_months ||
               ' month(s). See your updated repayment schedule.';

  -- --------------------------------------------------------------- write off
  ELSIF v_act.action = 'write_off' THEN
    UPDATE loans
       SET status = 'written_off', outstanding_principal = 0
     WHERE id = v_loan.id;
    UPDATE loan_installments
       SET status = 'cancelled'
     WHERE loan_id = v_loan.id AND status IN ('pending', 'partial');

    -- A negative earnings entry: the loss lands on the cycle in which the group
    -- decided to take it, so a share-out distributes profit net of write-offs.
    IF v_outstanding > 0 THEN
      INSERT INTO earnings_ledger (member_id, kind, amount, source_type, source_id)
      VALUES (v_loan.member_id, 'write_off', -v_outstanding, 'loan', v_loan.id);
    END IF;
    v_outstanding := 0;

    v_title := 'Loan written off';
    v_body  := 'The group has written off the remaining balance of your loan.';

  -- ------------------------------------------------- recover from savings
  ELSE
    -- Never recover more than is owed, nor more than the member actually holds.
    SELECT
        COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                   WHERE member_id = v_loan.member_id
                     AND submission_type = 'savings_deposit'
                     AND status = 'approved'), 0)
      + COALESCE((SELECT SUM(amount_paid) FROM monthly_fees
                   WHERE member_id = v_loan.member_id), 0)
      + COALESCE((SELECT SUM(delta) FROM savings_adjustments
                   WHERE target_member_id = v_loan.member_id AND status = 'approved'), 0)
    INTO v_savings;

    v_amount := least(v_act.amount, v_outstanding, v_savings);
    IF v_amount <= 0 THEN
      RAISE EXCEPTION 'Nothing to recover: outstanding %, member savings %',
        v_outstanding, v_savings;
    END IF;

    -- The member's claim on the pool shrinks…
    INSERT INTO savings_adjustments
      (target_member_id, requested_by, delta, reason, status, applied_at)
    VALUES (v_loan.member_id, v_act.requested_by, -v_amount,
            'Loan recovery: ' || v_act.reason, 'approved', now());

    -- …and this cancels the cash movement that adjustment would otherwise imply.
    INSERT INTO loan_recoveries (loan_id, member_id, amount, action_id)
    VALUES (v_loan.id, v_loan.member_id, v_amount, v_act.id);

    v_outstanding := v_outstanding - v_amount;
    UPDATE loans SET outstanding_principal = v_outstanding WHERE id = v_loan.id;

    IF v_outstanding <= 0 THEN
      UPDATE loans SET status = 'closed' WHERE id = v_loan.id;
      UPDATE loan_installments
         SET status = 'cancelled'
       WHERE loan_id = v_loan.id AND status IN ('pending', 'partial');
    END IF;

    v_title := 'Loan settled from your savings';
    v_body  := v_amount || ' TZS of your savings was applied to your loan balance.';
  END IF;

  UPDATE loan_actions SET status = 'approved', applied_at = now() WHERE id = p_action_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'execute_loan_' || v_act.action, 'loan', v_loan.id,
          jsonb_build_object(
            'action_id',   p_action_id,
            'member_id',   v_loan.member_id,
            'principal',   v_loan.principal,
            'outstanding_before', v_loan.outstanding_principal,
            'outstanding_after',  v_outstanding,
            'amount',      v_act.amount,
            'term_months', v_act.term_months,
            'reason',      v_act.reason
          ));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_loan.member_id, 'loan_' || v_act.action, v_title, v_body,
          jsonb_build_object('loan_id', v_loan.id, 'action_id', p_action_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. Request / approve / cancel — same 2-of-N shape as pool edits (015).
--    The requester's vote does NOT auto-count, and an admin can never open or
--    approve an action against their OWN loan.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION request_loan_action(
  p_loan_id uuid, p_action text, p_reason text,
  p_amount numeric DEFAULT NULL, p_term_months int DEFAULT NULL
)
RETURNS uuid AS $$
DECLARE
  v_action_id    uuid;
  v_loan         loans%ROWTYPE;
  v_requester    text;
  v_member       text;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every loan action';
  END IF;
  IF p_action NOT IN ('restructure', 'write_off', 'recover_from_savings') THEN
    RAISE EXCEPTION 'Unknown loan action: %', p_action;
  END IF;

  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id;
  IF v_loan.id IS NULL         THEN RAISE EXCEPTION 'Loan not found';                  END IF;
  IF v_loan.status <> 'active' THEN RAISE EXCEPTION 'Only an active loan can be actioned'; END IF;
  IF v_loan.member_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot open an action against your own loan';
  END IF;

  IF p_action = 'restructure' THEN
    IF p_term_months IS NULL OR p_term_months < 1 OR p_term_months > 24 THEN
      RAISE EXCEPTION 'Term must be between 1 and 24 months';
    END IF;
  ELSIF p_action = 'recover_from_savings' THEN
    IF p_amount IS NULL OR p_amount <= 0 THEN
      RAISE EXCEPTION 'Enter the amount to recover';
    END IF;
  END IF;

  -- One open action per loan, so two admins can't approve conflicting outcomes.
  IF EXISTS (SELECT 1 FROM loan_actions WHERE loan_id = p_loan_id AND status = 'pending') THEN
    RAISE EXCEPTION 'This loan already has a pending action; cancel or approve it first';
  END IF;

  INSERT INTO loan_actions (loan_id, action, amount, term_months, reason, requested_by)
  VALUES (p_loan_id, p_action, p_amount, p_term_months, trim(p_reason), auth.uid())
  RETURNING id INTO v_action_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_loan_' || p_action, 'loan', p_loan_id,
          jsonb_build_object(
            'action_id',   v_action_id,
            'member_id',   v_loan.member_id,
            'amount',      p_amount,
            'term_months', p_term_months,
            'reason',      p_reason
          ));

  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  SELECT full_name INTO v_member    FROM profiles WHERE id = v_loan.member_id;
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'loan_action_requested',
         'Loan action proposed',
         COALESCE(v_requester, 'An admin') || ' proposed to ' ||
           replace(p_action, '_', ' ') || ' ' || COALESCE(v_member, 'a member') || '''s loan',
         jsonb_build_object('action_id', v_action_id, 'loan_id', p_loan_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles
   WHERE role = 'admin' AND is_active = true
     AND id <> auth.uid() AND id <> v_loan.member_id;
  v_required := least(2, v_other_admins);

  IF v_required = 0 THEN
    PERFORM execute_loan_action(v_action_id);
  END IF;

  RETURN v_action_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION approve_loan_action(p_action_id uuid)
RETURNS void AS $$
DECLARE
  v_act          loan_actions%ROWTYPE;
  v_borrower     uuid;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_act FROM loan_actions WHERE id = p_action_id FOR UPDATE;
  IF v_act.id IS NULL          THEN RAISE EXCEPTION 'Loan action not found';  END IF;
  IF v_act.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed'; END IF;
  IF v_act.requested_by = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;

  SELECT member_id INTO v_borrower FROM loans WHERE id = v_act.loan_id;
  IF v_borrower = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve an action on your own loan';
  END IF;

  BEGIN
    INSERT INTO loan_action_approvals (action_id, admin_id) VALUES (p_action_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this action';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles
   WHERE role = 'admin' AND is_active = true
     AND id <> v_act.requested_by AND id <> v_borrower;
  v_required := least(2, v_other_admins);

  SELECT count(*) INTO v_approvals FROM loan_action_approvals WHERE action_id = p_action_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_loan_action', 'loan', v_act.loan_id,
            jsonb_build_object(
              'action_id', p_action_id,
              'approvals', v_approvals,
              'required',  v_required
            ));
    RETURN;
  END IF;

  PERFORM execute_loan_action(p_action_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION cancel_loan_action(p_action_id uuid)
RETURNS void AS $$
DECLARE
  v_act loan_actions%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_act FROM loan_actions WHERE id = p_action_id;
  IF v_act.id IS NULL OR v_act.status <> 'pending' THEN RETURN; END IF;

  UPDATE loan_actions SET status = 'cancelled' WHERE id = p_action_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'cancel_loan_action', 'loan', v_act.loan_id,
          jsonb_build_object('action_id', p_action_id, 'action', v_act.action));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
