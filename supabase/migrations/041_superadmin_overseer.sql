-- 041_superadmin_overseer.sql — one overseer, unrestricted.
--
-- Until now every monetary or structural action needed two admin signatures
-- (008), and an admin's own money needed two REGARDLESS of how few admins exist
-- (036). This migration carves out a single "overseer": one profile that acts on
-- its own signature everywhere, on its own money included.
--
-- HOW THE BYPASS WORKS. Almost nothing here rewrites the money logic. Every
-- request_* function in this schema already ends with the same shape:
--
--     IF (SELECT count(*) FROM ..._approvals WHERE ...) >= required_approvals()
--     THEN PERFORM execute_...(v_id);
--
-- The requester's own signature is cast as part of the request. So making
-- required_approvals() return 1 for the overseer means the overseer's request
-- EXECUTES INSIDE THE REQUEST CALL — savings edits, pool edits, role changes,
-- setting changes, loan actions, cycle closes, social grants, member deletions
-- and payment voids all complete on one call, and never reach the approve_*
-- queue where the "you cannot approve your own request" guards live. Those
-- guards are therefore left standing and untouched for every other admin.
--
-- WHAT IS DELIBERATELY *NOT* BYPASSED. The lending caps in approve_loan — the
-- pool fraction and the contribution multiplier — still apply to the overseer.
-- They are not admin confirmations, they are group lending limits, and they are
-- already group_settings rows the overseer can now change alone and instantly
-- through request_setting_change. Hardcoding a second bypass would only hide
-- the change from the settings history.
--
-- Requires 040.

-- --------------------------------------------------------------------------
-- 1. The flag.
--
--    A column rather than a fourth `role` value, because role = 'admin' is what
--    is_admin() and every RLS policy in the schema key off. A separate role
--    would have silently locked the overseer out of the whole application.
-- --------------------------------------------------------------------------

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS is_superadmin boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN profiles.is_superadmin IS
  'The overseer. Acts on a single signature everywhere. Set only from the service role.';

-- "He is the overseer", singular. A partial unique index over a constant makes
-- a second overseer a constraint violation rather than a quiet governance hole.
CREATE UNIQUE INDEX IF NOT EXISTS one_overseer_only
  ON profiles ((true)) WHERE is_superadmin;

-- --------------------------------------------------------------------------
-- 2. The gate.
--
--    Mirrors is_admin() from 034: SECURITY DEFINER to bypass RLS, pinned
--    search_path, and is_active checked — a deactivated profile acts on nothing.
--    Note it does NOT require role = 'admin': the overseer keeps authority even
--    mid-role-change, and part 5 stops that role from being changed at all.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION is_superadmin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
     WHERE id = auth.uid() AND is_superadmin = true AND is_active = true
  );
$$;

-- --------------------------------------------------------------------------
-- 3. One signature is a quorum.
--
--    This single function is what every 2-of-N flow consults, so this is the
--    whole governance bypass. For everyone else the rule is unchanged:
--    least(2, active admins).
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION required_approvals()
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN is_superadmin() THEN 1
    ELSE (SELECT least(2, count(*)::int)
            FROM profiles WHERE role = 'admin' AND is_active = true)
  END;
$$;

-- --------------------------------------------------------------------------
-- 4. The overseer's own money.
--
--    036 made an admin recording their OWN payment a permanent two-signature
--    matter — greatest(required_approvals(), 2) — specifically so a one-admin
--    group could not degrade it. That was a deliberate group decision, and this
--    is the one place in this migration that reverses one. The overseer now
--    settles their own recorded payments alone. Every other admin still cannot.
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

  IF s.recorded_by IS NOT NULL AND s.submission_type = 'monthly_fee' THEN
    RETURN 1;
  END IF;

  RETURN required_approvals();
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. Protecting the office.
--
--    Two separate problems, both closed by one trigger rather than by editing
--    the dozen functions that could otherwise reach profiles:
--
--    (a) ESCALATION. `Admin can update any profile` (003) is a bare USING
--        clause with no WITH CHECK, so every admin can already UPDATE any
--        column of any profile. Without this trigger, adding is_superadmin
--        would hand all of them a one-statement path to making THEMSELVES
--        overseer. The flag is now settable only where auth.uid() is NULL —
--        i.e. from the service role, off the public API.
--
--    (b) REMOVAL. The overseer cannot be demoted, deactivated or deleted
--        through the app at all, by any number of admins. The recovery path is
--        deliberately the same as the setting path: the service-role key.
--        Whoever holds it clears the flag first, and only then can the ordinary
--        role-change and exit flows touch that profile again.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION protect_overseer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.is_superadmin AND auth.uid() IS NOT NULL THEN
      RAISE EXCEPTION 'The overseer cannot be removed from inside the app.';
    END IF;
    RETURN OLD;
  END IF;

  -- (a) Who may hand out the office.
  IF NEW.is_superadmin IS DISTINCT FROM OLD.is_superadmin AND auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION
      'The overseer flag is not settable from the app. Use scripts/set-overseer.mjs with the service-role key.';
  END IF;

  -- (b) While the office is held, the profile holding it is immovable.
  IF OLD.is_superadmin AND NEW.is_superadmin THEN
    IF NEW.role <> 'admin' THEN
      RAISE EXCEPTION 'The overseer cannot be demoted. Clear is_superadmin first.';
    END IF;
    IF NEW.is_active = false THEN
      RAISE EXCEPTION 'The overseer cannot be deactivated. Clear is_superadmin first.';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_overseer_trg ON profiles;
CREATE TRIGGER protect_overseer_trg
  BEFORE UPDATE OR DELETE ON profiles
  FOR EACH ROW EXECUTE FUNCTION protect_overseer();

-- --------------------------------------------------------------------------
-- 6. The loan-free-admin mandate.
--
--    035's approve_loan refuses a loan to an admin when that would leave no
--    loan-free admin. Unlike the lending caps in the same function, this one is
--    hardcoded rather than a group_settings row, so the overseer cannot lift it
--    by changing a setting. It is exempted here instead. The body below is
--    035's, unchanged except for the one marked line.
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
-- 7. Recording the overseer's own payment in a one-admin group.
--
--    036's record_payment refuses a self-recorded payment outright when fewer
--    than two admins exist, and that check runs BEFORE submission_threshold —
--    so part 4 alone would not reach it. Without this the overseer of a
--    one-admin group is the only member who cannot have a payment recorded.
--    The body below is 036's, unchanged except for the one marked guard.
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
-- 8. The flows that never asked required_approvals().
--
--    Part 3 is not, on its own, the whole bypass. Seven workflows — savings
--    edits, pool edits, role changes, settings, loan actions, cycle close and
--    withdrawals — compute their own quorum inline instead of calling
--    required_approvals():
--
--        SELECT count(*) INTO v_other_admins
--          FROM profiles WHERE role = 'admin' AND is_active AND id <> auth.uid();
--        v_required := least(2, v_other_admins);
--        IF v_required = 0 THEN PERFORM execute_...(v_id); END IF;
--
--    Changing required_approvals() alone leaves every one of them untouched, so
--    the overseer's request would sit pending exactly like anyone else's. The
--    thirteen bodies below are their current definitions, reproduced verbatim
--    from the migrations named against each, with two mechanical edits and
--    nothing else — each marked `-- OVERSEER` in place:
--
--      * the quorum line becomes 0 for the overseer, which is what makes the
--        request execute inside its own call; and
--      * the "you cannot approve your own request" guards gain
--        `AND NOT is_superadmin()`, so the overseer can also carry a request
--        that someone else opened, or one that names the overseer.
--
--    Every one of these edits is conditional on is_superadmin(). For all other
--    admins each function behaves exactly as it did before this migration.
-- --------------------------------------------------------------------------

-- request_savings_edit — from 013_savings_edits.sql, unchanged but for the 1 quorum site and 0 self-guard(s) marked OVERSEER.
CREATE OR REPLACE FUNCTION request_savings_edit(
  p_target_member_id uuid,
  p_delta            numeric,
  p_reason           text
)
RETURNS uuid AS $$
DECLARE
  v_request_id    uuid;
  v_target_role   text;
  v_target_name   text;
  v_requester     text;
  v_other_admins  int;
  v_required      int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_delta = 0   THEN RAISE EXCEPTION 'Delta must be non-zero'; END IF;
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every savings edit';
  END IF;

  SELECT role, full_name INTO v_target_role, v_target_name
    FROM profiles WHERE id = p_target_member_id;
  IF v_target_role IS NULL THEN RAISE EXCEPTION 'Member not found'; END IF;

  -- Admins may only target non-admins or themselves; never another admin.
  IF v_target_role = 'admin' AND p_target_member_id <> auth.uid() THEN
    RAISE EXCEPTION 'Admins cannot edit another admin''s savings';
  END IF;

  -- Block overlapping pending requests for the same target.
  IF EXISTS (
    SELECT 1 FROM savings_adjustments
     WHERE target_member_id = p_target_member_id AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A pending savings edit already exists for this member';
  END IF;

  INSERT INTO savings_adjustments (target_member_id, requested_by, delta, reason)
  VALUES (p_target_member_id, auth.uid(), p_delta, trim(p_reason))
  RETURNING id INTO v_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_savings_edit', 'profile', p_target_member_id,
          jsonb_build_object(
            'request_id',  v_request_id,
            'delta',       p_delta,
            'reason',      p_reason,
            'target_name', v_target_name
          ));

  -- Notify every other admin so they can act.
  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'savings_edit_requested',
         'Savings edit requested',
         COALESCE(v_requester, 'An admin') || ' wants to adjust ' ||
           COALESCE(v_target_name, 'a member') || '''s savings by ' ||
           p_delta || ' TZS',
         jsonb_build_object(
           'request_id', v_request_id,
           'target_id',  p_target_member_id,
           'delta',      p_delta
         )
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  -- Required = min(2, other active admin count). With a single admin in the
  -- system there are no "others" so the request auto-applies.
  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  v_required := CASE WHEN is_superadmin() THEN 0 ELSE least(2, v_other_admins) END;  -- OVERSEER

  IF v_required = 0 THEN
    PERFORM execute_savings_edit(v_request_id);
  END IF;

  RETURN v_request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- approve_savings_edit — from 013_savings_edits.sql, unchanged but for the 1 quorum site and 2 self-guard(s) marked OVERSEER.
CREATE OR REPLACE FUNCTION approve_savings_edit(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request      savings_adjustments%ROWTYPE;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM savings_adjustments WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Edit request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed'; END IF;

  -- "Other admins must approve" — neither the requester nor the target may vote.
  IF v_request.requested_by = auth.uid() AND NOT is_superadmin() THEN  -- OVERSEER
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;
  IF v_request.target_member_id = auth.uid() AND NOT is_superadmin() THEN  -- OVERSEER
    RAISE EXCEPTION 'You cannot approve an edit to your own savings';
  END IF;

  BEGIN
    INSERT INTO savings_adjustment_approvals (adjustment_id, admin_id)
    VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this edit';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_request.requested_by;
  v_required := CASE WHEN is_superadmin() THEN 0 ELSE least(2, v_other_admins) END;  -- OVERSEER

  SELECT count(*) INTO v_approvals FROM savings_adjustment_approvals WHERE adjustment_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_savings_edit', 'profile',
            v_request.target_member_id,
            jsonb_build_object(
              'request_id', p_request_id,
              'approvals',  v_approvals,
              'required',   v_required
            ));
    RETURN;
  END IF;

  PERFORM execute_savings_edit(p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- request_pool_edit — from 015_pool_edits.sql, unchanged but for the 1 quorum site and 0 self-guard(s) marked OVERSEER.
CREATE OR REPLACE FUNCTION request_pool_edit(p_delta numeric, p_reason text)
RETURNS uuid AS $$
DECLARE
  v_request_id   uuid;
  v_requester    text;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_delta = 0   THEN RAISE EXCEPTION 'Delta must be non-zero'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every pool edit';
  END IF;

  -- Block overlapping pending requests so the pool doesn't get adjusted twice
  -- on the same conceptual change. Cancelling a pending request unblocks the
  -- next one.
  IF EXISTS (SELECT 1 FROM pool_adjustments WHERE status = 'pending') THEN
    RAISE EXCEPTION 'A pending pool edit already exists; cancel or approve it first';
  END IF;

  INSERT INTO pool_adjustments (requested_by, delta, reason)
  VALUES (auth.uid(), p_delta, trim(p_reason))
  RETURNING id INTO v_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_pool_edit', 'pool', NULL,
          jsonb_build_object(
            'request_id', v_request_id,
            'delta',      p_delta,
            'reason',     p_reason
          ));

  -- Notify every other active admin so they can act.
  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'pool_edit_requested',
         'Pool edit requested',
         COALESCE(v_requester, 'An admin') || ' wants to adjust the group pool by ' ||
           p_delta || ' TZS',
         jsonb_build_object(
           'request_id', v_request_id,
           'delta',      p_delta
         )
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  v_required := CASE WHEN is_superadmin() THEN 0 ELSE least(2, v_other_admins) END;  -- OVERSEER

  IF v_required = 0 THEN
    PERFORM execute_pool_edit(v_request_id);
  END IF;

  RETURN v_request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- approve_pool_edit — from 015_pool_edits.sql, unchanged but for the 1 quorum site and 1 self-guard(s) marked OVERSEER.
CREATE OR REPLACE FUNCTION approve_pool_edit(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request      pool_adjustments%ROWTYPE;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM pool_adjustments WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Pool edit request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed';   END IF;

  IF v_request.requested_by = auth.uid() AND NOT is_superadmin() THEN  -- OVERSEER
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;

  BEGIN
    INSERT INTO pool_adjustment_approvals (adjustment_id, admin_id)
    VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this edit';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_request.requested_by;
  v_required := CASE WHEN is_superadmin() THEN 0 ELSE least(2, v_other_admins) END;  -- OVERSEER

  SELECT count(*) INTO v_approvals FROM pool_adjustment_approvals WHERE adjustment_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_pool_edit', 'pool', NULL,
            jsonb_build_object(
              'request_id', p_request_id,
              'approvals',  v_approvals,
              'required',   v_required
            ));
    RETURN;
  END IF;

  PERFORM execute_pool_edit(p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- request_role_change — from 016_role_changes.sql, unchanged but for the 1 quorum site and 0 self-guard(s) marked OVERSEER.
CREATE OR REPLACE FUNCTION request_role_change(
  p_target_member_id uuid,
  p_change_type      text,
  p_reason           text
)
RETURNS uuid AS $$
DECLARE
  v_request_id    uuid;
  v_target_role   text;
  v_target_name   text;
  v_admin_count   int;
  v_other_admins  int;
  v_required      int;
  v_requester     text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_change_type NOT IN ('promote', 'demote') THEN
    RAISE EXCEPTION 'Invalid change_type (use promote or demote)';
  END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every role change';
  END IF;

  SELECT role, full_name INTO v_target_role, v_target_name
    FROM profiles WHERE id = p_target_member_id;
  IF v_target_role IS NULL THEN RAISE EXCEPTION 'Member not found'; END IF;

  IF p_change_type = 'promote' THEN
    IF v_target_role = 'admin' THEN
      RAISE EXCEPTION 'Member is already an admin';
    END IF;
  ELSE  -- demote
    IF v_target_role <> 'admin' THEN
      RAISE EXCEPTION 'Member is not an admin';
    END IF;
    SELECT count(*) INTO v_admin_count
      FROM profiles WHERE role = 'admin' AND is_active = true;
    IF v_admin_count <= 1 THEN
      RAISE EXCEPTION 'Cannot revoke the last remaining admin';
    END IF;
  END IF;

  -- Block overlapping pending requests for the same target.
  IF EXISTS (
    SELECT 1 FROM role_change_requests
     WHERE target_member_id = p_target_member_id AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A pending role-change request already exists for this member';
  END IF;

  INSERT INTO role_change_requests (target_member_id, requested_by, change_type, reason)
  VALUES (p_target_member_id, auth.uid(), p_change_type, trim(p_reason))
  RETURNING id INTO v_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_role_change', 'profile', p_target_member_id,
          jsonb_build_object(
            'request_id',  v_request_id,
            'change_type', p_change_type,
            'reason',      p_reason,
            'target_name', v_target_name
          ));

  -- Notify every OTHER active admin so they can vote.
  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'role_change_requested',
         CASE WHEN p_change_type = 'promote'
              THEN 'Admin promotion requested'
              ELSE 'Admin revocation requested'
         END,
         COALESCE(v_requester, 'An admin') || ' wants to ' || p_change_type || ' ' ||
           COALESCE(v_target_name, 'a member'),
         jsonb_build_object(
           'request_id',  v_request_id,
           'target_id',   p_target_member_id,
           'change_type', p_change_type
         )
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  v_required := CASE WHEN is_superadmin() THEN 0 ELSE least(2, v_other_admins) END;  -- OVERSEER

  IF v_required = 0 THEN
    PERFORM execute_role_change(v_request_id);
  END IF;

  RETURN v_request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- approve_role_change — from 016_role_changes.sql, unchanged but for the 1 quorum site and 2 self-guard(s) marked OVERSEER.
CREATE OR REPLACE FUNCTION approve_role_change(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request      role_change_requests%ROWTYPE;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM role_change_requests WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Role-change request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed';     END IF;

  IF v_request.requested_by = auth.uid() AND NOT is_superadmin() THEN  -- OVERSEER
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;
  IF v_request.target_member_id = auth.uid() AND NOT is_superadmin() THEN  -- OVERSEER
    RAISE EXCEPTION 'You cannot approve a role change targeting yourself';
  END IF;

  BEGIN
    INSERT INTO role_change_approvals (request_id, admin_id)
    VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this request';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_request.requested_by;
  v_required := CASE WHEN is_superadmin() THEN 0 ELSE least(2, v_other_admins) END;  -- OVERSEER

  SELECT count(*) INTO v_approvals FROM role_change_approvals WHERE request_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_role_change', 'profile',
            v_request.target_member_id,
            jsonb_build_object(
              'request_id', p_request_id,
              'approvals',  v_approvals,
              'required',   v_required
            ));
    RETURN;
  END IF;

  PERFORM execute_role_change(p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- request_setting_change — from 020_group_settings.sql, unchanged but for the 1 quorum site and 0 self-guard(s) marked OVERSEER.
CREATE OR REPLACE FUNCTION request_setting_change(
  p_key text, p_new_value numeric, p_reason text
)
RETURNS uuid AS $$
DECLARE
  v_change_id    uuid;
  v_current      group_settings%ROWTYPE;
  v_requester    text;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required for every rule change';
  END IF;

  SELECT * INTO v_current FROM group_settings WHERE key = p_key;
  IF v_current.key IS NULL THEN RAISE EXCEPTION 'Unknown setting: %', p_key; END IF;

  IF p_new_value = v_current.value THEN
    RAISE EXCEPTION 'That is already the current value';
  END IF;
  IF p_new_value < v_current.min_value OR p_new_value > v_current.max_value THEN
    RAISE EXCEPTION '% must be between % and %',
      v_current.label, v_current.min_value, v_current.max_value;
  END IF;

  -- One pending change per key, so two admins can't approve conflicting values.
  IF EXISTS (SELECT 1 FROM setting_changes WHERE key = p_key AND status = 'pending') THEN
    RAISE EXCEPTION 'A pending change for this setting already exists; cancel or approve it first';
  END IF;

  INSERT INTO setting_changes (key, old_value, new_value, reason, requested_by)
  VALUES (p_key, v_current.value, p_new_value, trim(p_reason), auth.uid())
  RETURNING id INTO v_change_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_setting_change', 'setting', NULL,
          jsonb_build_object(
            'change_id', v_change_id,
            'key',       p_key,
            'old_value', v_current.value,
            'new_value', p_new_value,
            'reason',    p_reason
          ));

  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'setting_change_requested',
         'Rule change proposed',
         COALESCE(v_requester, 'An admin') || ' wants to change ' || v_current.label ||
           ' from ' || v_current.value || ' to ' || p_new_value,
         jsonb_build_object('change_id', v_change_id, 'key', p_key)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  v_required := CASE WHEN is_superadmin() THEN 0 ELSE least(2, v_other_admins) END;  -- OVERSEER

  IF v_required = 0 THEN
    PERFORM execute_setting_change(v_change_id);
  END IF;

  RETURN v_change_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- approve_setting_change — from 020_group_settings.sql, unchanged but for the 1 quorum site and 1 self-guard(s) marked OVERSEER.
CREATE OR REPLACE FUNCTION approve_setting_change(p_change_id uuid)
RETURNS void AS $$
DECLARE
  v_change       setting_changes%ROWTYPE;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_change FROM setting_changes WHERE id = p_change_id FOR UPDATE;
  IF v_change.id IS NULL          THEN RAISE EXCEPTION 'Setting change not found'; END IF;
  IF v_change.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed'; END IF;
  IF v_change.requested_by = auth.uid() AND NOT is_superadmin() THEN  -- OVERSEER
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;

  BEGIN
    INSERT INTO setting_change_approvals (change_id, admin_id)
    VALUES (p_change_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this change';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_change.requested_by;
  v_required := CASE WHEN is_superadmin() THEN 0 ELSE least(2, v_other_admins) END;  -- OVERSEER

  SELECT count(*) INTO v_approvals FROM setting_change_approvals WHERE change_id = p_change_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_setting_change', 'setting', NULL,
            jsonb_build_object(
              'change_id', p_change_id,
              'approvals', v_approvals,
              'required',  v_required
            ));
    RETURN;
  END IF;

  PERFORM execute_setting_change(p_change_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- request_loan_action — from 022_loan_distress.sql, unchanged but for the 1 quorum site and 0 self-guard(s) marked OVERSEER.
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
  v_required := CASE WHEN is_superadmin() THEN 0 ELSE least(2, v_other_admins) END;  -- OVERSEER

  IF v_required = 0 THEN
    PERFORM execute_loan_action(v_action_id);
  END IF;

  RETURN v_action_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- approve_loan_action — from 022_loan_distress.sql, unchanged but for the 1 quorum site and 2 self-guard(s) marked OVERSEER.
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
  IF v_act.requested_by = auth.uid() AND NOT is_superadmin() THEN  -- OVERSEER
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;

  SELECT member_id INTO v_borrower FROM loans WHERE id = v_act.loan_id;
  IF v_borrower = auth.uid() AND NOT is_superadmin() THEN  -- OVERSEER
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
  v_required := CASE WHEN is_superadmin() THEN 0 ELSE least(2, v_other_admins) END;  -- OVERSEER

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

-- request_cycle_close — from 024_share_out.sql, unchanged but for the 1 quorum site and 0 self-guard(s) marked OVERSEER.
CREATE OR REPLACE FUNCTION request_cycle_close(p_cycle_id uuid, p_mode text, p_reason text)
RETURNS uuid AS $$
DECLARE
  v_closure_id   uuid;
  v_cycle        cycles%ROWTYPE;
  v_open_loans   int;
  v_open_subs    int;
  v_requester    text;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_mode NOT IN ('earnings_only', 'full_shareout') THEN
    RAISE EXCEPTION 'Unknown share-out mode: %', p_mode;
  END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required to close a cycle';
  END IF;

  SELECT * INTO v_cycle FROM cycles WHERE id = p_cycle_id;
  IF v_cycle.id IS NULL       THEN RAISE EXCEPTION 'Cycle not found';           END IF;
  IF v_cycle.status <> 'open' THEN RAISE EXCEPTION 'This cycle is already closed'; END IF;

  -- Nothing may be in flight: a submission approved mid-close would land in a
  -- cycle whose numbers are already frozen.
  SELECT count(*) INTO v_open_subs FROM payment_submissions WHERE status = 'pending';
  IF v_open_subs > 0 THEN
    RAISE EXCEPTION 'Clear the % pending payment(s) before closing the cycle', v_open_subs;
  END IF;

  SELECT count(*) INTO v_open_loans FROM loans WHERE status IN ('pending', 'active');
  IF v_open_loans > 0 AND p_mode = 'full_shareout' THEN
    RAISE EXCEPTION
      'Cannot return everyone''s capital while % loan(s) are still out. Settle or write them off first, or close with earnings only.',
      v_open_loans;
  END IF;

  IF EXISTS (SELECT 1 FROM cycle_closures WHERE cycle_id = p_cycle_id AND status = 'pending') THEN
    RAISE EXCEPTION 'A closure request for this cycle is already open';
  END IF;

  INSERT INTO cycle_closures (cycle_id, mode, reason, requested_by)
  VALUES (p_cycle_id, p_mode, trim(p_reason), auth.uid())
  RETURNING id INTO v_closure_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'request_cycle_close', 'cycle', p_cycle_id,
          jsonb_build_object('closure_id', v_closure_id, 'mode', p_mode, 'reason', p_reason));

  SELECT full_name INTO v_requester FROM profiles WHERE id = auth.uid();
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'cycle_close_requested',
         'Cycle close proposed',
         COALESCE(v_requester, 'An admin') || ' proposed to close ' || v_cycle.name,
         jsonb_build_object('closure_id', v_closure_id, 'cycle_id', p_cycle_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  v_required := CASE WHEN is_superadmin() THEN 0 ELSE least(2, v_other_admins) END;  -- OVERSEER

  IF v_required = 0 THEN
    PERFORM execute_cycle_close(v_closure_id);
  END IF;

  RETURN v_closure_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- approve_cycle_close — from 024_share_out.sql, unchanged but for the 1 quorum site and 1 self-guard(s) marked OVERSEER.
CREATE OR REPLACE FUNCTION approve_cycle_close(p_closure_id uuid)
RETURNS void AS $$
DECLARE
  v_closure      cycle_closures%ROWTYPE;
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_closure FROM cycle_closures WHERE id = p_closure_id FOR UPDATE;
  IF v_closure.id IS NULL          THEN RAISE EXCEPTION 'Closure request not found'; END IF;
  IF v_closure.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed'; END IF;
  IF v_closure.requested_by = auth.uid() AND NOT is_superadmin() THEN  -- OVERSEER
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;

  BEGIN
    INSERT INTO cycle_closure_approvals (closure_id, admin_id) VALUES (p_closure_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this closure';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_closure.requested_by;
  v_required := CASE WHEN is_superadmin() THEN 0 ELSE least(2, v_other_admins) END;  -- OVERSEER

  SELECT count(*) INTO v_approvals FROM cycle_closure_approvals WHERE closure_id = p_closure_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_cycle_close', 'cycle', v_closure.cycle_id,
            jsonb_build_object('closure_id', p_closure_id,
                               'approvals', v_approvals, 'required', v_required));
    RETURN;
  END IF;

  PERFORM execute_cycle_close(p_closure_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- approve_withdrawal — from 025_withdrawals_and_exit.sql, unchanged but for the 1 quorum site and 1 self-guard(s) marked OVERSEER.
CREATE OR REPLACE FUNCTION approve_withdrawal(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_req          withdrawal_requests%ROWTYPE;
  v_max          numeric(14,2);
  v_approvals    int;
  v_other_admins int;
  v_required     int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_req FROM withdrawal_requests WHERE id = p_request_id FOR UPDATE;
  IF v_req.id IS NULL          THEN RAISE EXCEPTION 'Withdrawal not found';    END IF;
  IF v_req.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';       END IF;
  IF v_req.member_id = auth.uid() AND NOT is_superadmin() THEN  -- OVERSEER
    RAISE EXCEPTION 'You cannot approve your own withdrawal';
  END IF;

  BEGIN
    INSERT INTO withdrawal_approvals (request_id, admin_id) VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this withdrawal';
  END;

  SELECT COALESCE(count(*), 0) INTO v_other_admins
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_req.member_id;
  v_required := CASE WHEN is_superadmin() THEN 0 ELSE least(2, v_other_admins) END;  -- OVERSEER

  SELECT count(*) INTO v_approvals FROM withdrawal_approvals WHERE request_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_withdrawal', 'withdrawal', p_request_id,
            jsonb_build_object('approvals', v_approvals, 'required', v_required));
    RETURN;
  END IF;

  -- Re-check the ceiling at the moment of approval: the pool and the member's
  -- balance may both have moved since the request was opened. The request's own
  -- amount is excluded from the "committed" subtraction inside member_withdrawable
  -- by adding it back here.
  SELECT withdrawable_tzs + v_req.amount INTO v_max FROM member_withdrawable(v_req.member_id);
  IF v_req.amount > v_max THEN
    RAISE EXCEPTION 'Only % can be withdrawn now — the pool or their balance has changed', v_max;
  END IF;

  UPDATE withdrawal_requests
     SET status = 'approved', approved_at = now()
   WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_withdrawal', 'withdrawal', p_request_id,
          jsonb_build_object('member_id', v_req.member_id, 'amount', v_req.amount));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_req.member_id, 'withdrawal_approved', 'Withdrawal approved',
          'Your withdrawal of ' || v_req.amount || ' TZS was approved and will be paid out.',
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 9. Two self-guards on flows that DO use required_approvals().
--
--    Member deletion and payment-submission approval already read their
--    threshold from part 3, so only their self-approval guards stand in the
--    overseer's way. Same mechanical edit, same verbatim bodies.
-- --------------------------------------------------------------------------

-- approve_member_deletion — from 010_member_deletion.sql, unchanged but for the self-guard(s) marked OVERSEER.
CREATE OR REPLACE FUNCTION approve_member_deletion(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_request   deletion_requests%ROWTYPE;
  v_approvals int;
  v_required  int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_request FROM deletion_requests WHERE id = p_request_id FOR UPDATE;
  IF v_request.id IS NULL          THEN RAISE EXCEPTION 'Deletion request not found'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'Request already processed';   END IF;
  IF v_request.target_member_id = auth.uid() AND NOT is_superadmin() THEN  -- OVERSEER
    RAISE EXCEPTION 'You cannot approve your own deletion';
  END IF;

  BEGIN
    INSERT INTO deletion_approvals (request_id, admin_id) VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this deletion';
  END;

  v_required := required_approvals();
  SELECT count(*) INTO v_approvals FROM deletion_approvals WHERE request_id = p_request_id;

  IF v_approvals < v_required THEN
    INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
    VALUES (auth.uid(), 'partial_approve_member_deletion', 'profile',
            v_request.target_member_id,
            jsonb_build_object(
              'request_id', p_request_id,
              'approvals',  v_approvals,
              'required',   v_required
            ));
    RETURN;
  END IF;

  -- Threshold reached → execute deletion.
  PERFORM execute_member_deletion(p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- approve_submission — from 036_admin_recording.sql, unchanged but for the self-guard(s) marked OVERSEER.
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
  IF s.member_id = auth.uid() AND NOT is_superadmin() THEN RAISE EXCEPTION 'Cannot approve your own submission'; END IF;  -- OVERSEER

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
