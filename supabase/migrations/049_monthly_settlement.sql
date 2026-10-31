-- 049_monthly_settlement.sql — settle the whole group's month in one action.
--
-- THE PROBLEM. At the monthly meeting (the last Saturday, where all the group's
-- money moves at once) fourteen members hand over their fee and thirteen of them
-- their loan interest. The fee sheet (036) already batches the fees. The interest
-- has no batch at all: it is the single-payment form, thirteen times over, and then
-- a second admin approving each of the thirteen one by one.
--
-- THE SHAPE. One sheet of everything due, everybody ticked. The admin says who did
-- NOT pay, presses once, and every ticked row posts in one transaction.
--
-- WHAT THIS IS NOT, stated because it is the obvious thing to get wrong:
--
--   * It does not move money. Like every other intake path it RECORDS money the
--     group has received. Nothing is pulled from a phone or out of anyone's savings.
--
--   * It does not change who signs what. 036's rules were the group's decisions and
--     they stand: another member's fee on one signature, interest and an admin's own
--     money on two, the overseer alone on everything (041). What goes away is the
--     per-member WORK — the row-by-row keying, and the row-by-row second signature.
--     A batch that needs a second admin needs that admin once.
--
-- THE AMOUNT IS THE SERVER'S. The client names rows and states the total it showed;
-- it never sends a figure per row. That is not tidiness. settle_submission's
-- waterfall sends anything above what an installment owes to EARLY PRINCIPAL, without
-- complaint, because for a single payment that is a legitimate instruction. In a
-- one-tap batch it would be a silent corruption: a row settled twice, or a figure
-- gone stale while waiting for a signature, would shorten someone's loan and nobody
-- would ever be told. So every amount here is read back from the row, under its lock,
-- immediately before it posts — and only ever covers penalty + interest, so there is
-- nothing left over to fall through.
--
-- THE FINAL INSTALLMENT. December's row carries the whole principal as well as the
-- interest. Only the interest is settled here: the row goes to 'partial', the member
-- still visibly owes the principal, and repaying it is the ordinary single-payment
-- form. That is deliberate — a principal repayment is the one figure at a meeting
-- that really does vary from member to member.
--
-- NOTIFICATIONS. 009's triggers write one row per submission to every admin and one
-- per status change to the member, and each of those fans out to a billable SMS (026).
-- A 27-row batch would write around 80. Batch rows are silent at the trigger, and in
-- their place: one message per member with their total, and one message to each other
-- admin when a signature is needed.
--
-- Requires 048 (and 036, 037, 041 for what it builds on).

-- --------------------------------------------------------------------------
-- 1. Schema: a payment remembers the batch it came from.
--
--    Nullable because almost nothing has one. It is also what the two notification
--    triggers below read, and how the approvals queue folds a batch into one card.
-- --------------------------------------------------------------------------

ALTER TABLE payment_submissions
  ADD COLUMN IF NOT EXISTS settlement_batch_id uuid;

COMMENT ON COLUMN payment_submissions.settlement_batch_id IS
  'The monthly settlement this row was recorded in (049). NULL for every payment keyed on its own.';

CREATE INDEX IF NOT EXISTS payment_submissions_settlement_batch_idx
  ON payment_submissions (settlement_batch_id)
  WHERE settlement_batch_id IS NOT NULL;

-- --------------------------------------------------------------------------
-- 2. Batch rows are quiet. Both bodies are 009's, with the one marked line added.
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

CREATE OR REPLACE FUNCTION notify_admins_on_new_submission()
RETURNS trigger AS $$
DECLARE
  v_member_name text;
BEGIN
  -- 049: the batch asks the other admins once, for the whole batch.
  IF NEW.settlement_batch_id IS NOT NULL THEN RETURN NEW; END IF;

  SELECT full_name INTO v_member_name FROM profiles WHERE id = NEW.member_id;
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'new_submission',
         'New payment to review',
         COALESCE(v_member_name, 'A member') || ' submitted a ' || NEW.submission_type ||
           ' for ' || NEW.amount_claimed || ' TZS',
         jsonb_build_object('submission_id', NEW.id, 'member_id', NEW.member_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 3. settlement_due_rows — the one definition of what a batch can settle.
--
--    Read by the sheet, by the recording and again at the second signature, so the
--    three cannot disagree. "Due" means the due date has arrived, the same rule as
--    feesDueNow and installmentsDueNow: since 043/044 the due date IS the meeting.
--
--    `amount` is what clears the row without touching principal: penalty + base for a
--    fee, penalty + interest for an installment. The penalty has to be in it because
--    the waterfall takes penalty first — offering the interest alone on an overdue
--    row would leave that row's interest short.
--
--    Private, and revoked in the same breath, for the reason 036 gives.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION settlement_due_rows()
RETURNS TABLE (
  kind               text,
  related_id         uuid,
  member_id          uuid,
  full_name          text,
  due_date           date,
  period             date,
  installment_number int,
  base               numeric,
  penalty            numeric,
  amount             numeric,
  has_pending        boolean
) AS $$
  SELECT 'fee'::text, f.id, f.member_id, p.full_name, f.due_date, f.period, NULL::int,
         f.remaining::numeric, f.penalty_due::numeric, (f.remaining + f.penalty_due)::numeric,
         EXISTS (SELECT 1 FROM payment_submissions s
                  WHERE s.submission_type = 'monthly_fee'
                    AND s.related_id = f.id AND s.status = 'pending')
    FROM v_fee_status_money f
    JOIN profiles p ON p.id = f.member_id AND p.is_active = true
   WHERE f.remaining > 0
     AND f.status <> 'paid'
     AND f.due_date <= today_eat()

  UNION ALL

  SELECT 'interest'::text, i.id, l.member_id, p.full_name, i.due_date, NULL::date, i.installment_number,
         i.interest_remaining::numeric, i.penalty_due::numeric,
         (i.interest_remaining + i.penalty_due)::numeric,
         EXISTS (SELECT 1 FROM payment_submissions s
                  WHERE s.submission_type = 'loan_installment'
                    AND s.related_id = i.id AND s.status = 'pending')
    FROM v_installment_status_money i
    JOIN loans l    ON l.id = i.loan_id AND l.status = 'active'
    JOIN profiles p ON p.id = l.member_id AND p.is_active = true
   WHERE i.interest_remaining > 0
     AND i.status NOT IN ('paid', 'cancelled')
     AND i.due_date <= today_eat();
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION settlement_due_rows() FROM PUBLIC, anon, authenticated;

-- --------------------------------------------------------------------------
-- 4. One message per member: their total, at the moment it posted.
--
--    Private. A member whose fee posts now and whose interest posts on the second
--    signature hears twice, because those are two different moments their money moved
--    — still not once per row and once per admin.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION notify_settlement_members(p_submission_ids uuid[])
RETURNS void AS $$
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT s.member_id, 'settlement_recorded', 'Your monthly payment was recorded',
         fmt_tzs(SUM(s.amount_claimed)),
         jsonb_build_object('amount', SUM(s.amount_claimed),
                            'batch_id', min(s.settlement_batch_id::text))
    FROM payment_submissions s
   WHERE s.id = ANY(p_submission_ids)
   GROUP BY s.member_id;
$$ LANGUAGE sql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION notify_settlement_members(uuid[]) FROM PUBLIC, anon, authenticated;

-- --------------------------------------------------------------------------
-- 5. monthly_settlement_sheet — what the admin sees.
--
--    Rows already waiting on a signature are left off. If they stayed, a second admin
--    could settle a row the first had already recorded, and the first admin's row
--    would then land on an installment with nothing left to pay.
--
--    needs_second_signature is the warning shown before the tap, and it mirrors
--    submission_threshold (041) for a row that does not exist yet. What actually
--    decides is still submission_threshold, on the real row; 22_monthly_settlement
--    asserts the two agree.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION monthly_settlement_sheet()
RETURNS TABLE (
  kind                   text,
  related_id             uuid,
  member_id              uuid,
  full_name              text,
  due_date               date,
  period                 date,
  installment_number     int,
  base                   numeric,
  penalty                numeric,
  amount                 numeric,
  needs_second_signature boolean
) AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  RETURN QUERY
    SELECT d.kind, d.related_id, d.member_id, d.full_name, d.due_date, d.period,
           d.installment_number, d.base, d.penalty, d.amount,
           CASE
             WHEN is_superadmin()          THEN false
             WHEN d.member_id = auth.uid() THEN true
             WHEN d.kind = 'fee'           THEN false
             ELSE required_approvals() > 1
           END
      FROM settlement_due_rows() d
     WHERE NOT d.has_pending
     ORDER BY d.full_name, d.member_id, d.kind, d.due_date;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION monthly_settlement_sheet() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION monthly_settlement_sheet() TO authenticated;

-- --------------------------------------------------------------------------
-- 6. record_monthly_settlement — the one tap.
--
--    Entries are `[{"kind": "fee"|"interest", "id": uuid}]`; p_expected_total is the
--    figure the admin was looking at. Each row is locked, its amount read back under
--    that lock, and it then goes through the same settle_submission as every other
--    payment, so there is still exactly one implementation of the waterfall.
--
--    All-or-nothing: one bad row, or a total that disagrees with what was shown, and
--    the whole batch rolls back. The total is checked after posting because a row's
--    amount can only be known under its lock, and rolling back costs nothing.
--
--    Rows are taken in a fixed order so two admins pressing at once wait for each
--    other instead of deadlocking; the second then finds nothing left to settle and
--    is told so, which is why pressing twice can never pay anyone twice.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION record_monthly_settlement(p_entries jsonb, p_expected_total numeric)
RETURNS jsonb AS $$
DECLARE
  v_batch          uuid := gen_random_uuid();
  v_entry          jsonb;
  v_kind           text;
  v_id             uuid;
  v_row            record;
  v_sub            uuid;
  v_total          numeric(14,2) := 0;
  v_settled        uuid[] := '{}';
  v_settled_total  numeric(14,2) := 0;
  v_awaiting_count int := 0;
  v_awaiting_total numeric(14,2) := 0;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_entries IS NULL OR jsonb_typeof(p_entries) <> 'array'
     OR jsonb_array_length(p_entries) = 0 THEN
    RAISE EXCEPTION 'Tick at least one member.';
  END IF;

  FOR v_entry IN
    SELECT e FROM jsonb_array_elements(p_entries) AS e ORDER BY e ->> 'kind', e ->> 'id'
  LOOP
    v_kind := v_entry ->> 'kind';
    v_id   := (v_entry ->> 'id')::uuid;

    IF v_kind = 'fee' THEN
      PERFORM 1 FROM monthly_fees WHERE id = v_id FOR UPDATE;
    ELSIF v_kind = 'interest' THEN
      PERFORM 1 FROM loan_installments WHERE id = v_id FOR UPDATE;
    ELSE
      RAISE EXCEPTION 'Unknown settlement kind: %', v_kind;
    END IF;

    SELECT * INTO v_row FROM settlement_due_rows() d
     WHERE d.kind = v_kind AND d.related_id = v_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Something on this sheet has already been settled or is not due yet. Nothing was recorded — reload and try again.';
    END IF;
    IF v_row.has_pending THEN
      RAISE EXCEPTION '% already has a payment waiting for a signature. Nothing was recorded — reload and try again.',
        v_row.full_name;
    END IF;

    INSERT INTO payment_submissions
      (member_id, submission_type, related_id, amount_claimed, recorded_by, settlement_batch_id)
    VALUES (v_row.member_id,
            CASE v_kind WHEN 'fee' THEN 'monthly_fee' ELSE 'loan_installment' END,
            v_id, v_row.amount, auth.uid(), v_batch)
    RETURNING id INTO v_sub;

    INSERT INTO submission_approvals (submission_id, admin_id, amount_received)
    VALUES (v_sub, auth.uid(), v_row.amount);

    IF submission_threshold(v_sub) <= 1 THEN
      PERFORM settle_submission(v_sub, v_row.amount);
      v_settled       := v_settled || v_sub;
      v_settled_total := v_settled_total + v_row.amount;
    ELSE
      -- Fail here, not silently later, for the reason 036's record_payment gives: a
      -- row nobody can sign would sit pending forever and block the cycle's close.
      -- The recorder has signed already and a member cannot sign their own, unless
      -- that member is the overseer (041).
      IF NOT EXISTS (
        SELECT 1 FROM profiles a
         WHERE a.role = 'admin' AND a.is_active = true
           AND a.id <> auth.uid()
           AND (a.id <> v_row.member_id OR a.is_superadmin)
      ) THEN
        RAISE EXCEPTION '% needs a second admin''s signature and no other admin can give it. Untick them and try again.',
          v_row.full_name;
      END IF;
      v_awaiting_count := v_awaiting_count + 1;
      v_awaiting_total := v_awaiting_total + v_row.amount;
    END IF;

    v_total := v_total + v_row.amount;
  END LOOP;

  IF v_total IS DISTINCT FROM p_expected_total THEN
    RAISE EXCEPTION 'The total is now % but this sheet showed %. Nothing was recorded — reload and check it again.',
      fmt_tzs(v_total), fmt_tzs(p_expected_total);
  END IF;

  PERFORM notify_settlement_members(v_settled);

  IF v_awaiting_count > 0 THEN
    INSERT INTO notifications (recipient_id, kind, title, body, data)
    SELECT p.id, 'settlement_awaiting_signature',
           'A monthly settlement needs your signature',
           fmt_tzs(v_awaiting_total),
           jsonb_build_object('batch_id', v_batch, 'amount', v_awaiting_total)
      FROM profiles p
     WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();
  END IF;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'record_monthly_settlement', 'submission', NULL,
          jsonb_build_object(
            'batch_id',       v_batch,
            'entries',        jsonb_array_length(p_entries),
            'total',          v_total,
            'settled_count',  coalesce(array_length(v_settled, 1), 0),
            'settled_total',  v_settled_total,
            'awaiting_count', v_awaiting_count,
            'awaiting_total', v_awaiting_total
          ));

  RETURN jsonb_build_object(
    'batch_id',       v_batch,
    'settled_count',  coalesce(array_length(v_settled, 1), 0),
    'settled_total',  v_settled_total,
    'awaiting_count', v_awaiting_count,
    'awaiting_total', v_awaiting_total
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION record_monthly_settlement(jsonb, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION record_monthly_settlement(jsonb, numeric) TO authenticated;

-- --------------------------------------------------------------------------
-- 7. A batch row posts only at exactly what its row still owes.
--
--    A batch can wait for its second signature, and a great deal can happen meanwhile.
--    Early principal on a later installment re-prices this one downward; a restructure
--    or a write-off cancels it; it may simply have been paid some other way. The figure
--    being signed is still the one the first admin recorded, and settle_submission
--    would post it regardless: the surplus to early principal, or onto a cancelled
--    installment, flipping a written-off loan to closed.
--
--    A trigger rather than a check in approve_monthly_settlement, because that is not
--    the only way to a row: approve_submission reaches settle_submission directly. This
--    fires on the status change settle_submission makes before it touches any money,
--    so there is no path around it, and nothing has moved when it refuses.
--
--    One consequence, stated plainly. With a penalty rate above zero, a row picks up a
--    penalty the day after its meeting, so a batch recorded on the Saturday and signed
--    on the Sunday is refused here and has to be rejected and run again. That fails
--    safe, and it is what a payment signed a day late already costs in the waterfall;
--    while the group's rate is zero it cannot happen.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION guard_settlement_row()
RETURNS trigger AS $$
DECLARE
  v_owed numeric;
  v_name text;
BEGIN
  IF NEW.settlement_batch_id IS NULL OR NEW.status <> 'approved' OR OLD.status <> 'pending' THEN
    RETURN NEW;
  END IF;

  SELECT d.amount INTO v_owed FROM settlement_due_rows() d
   WHERE d.related_id = NEW.related_id
     AND d.kind = CASE NEW.submission_type WHEN 'monthly_fee' THEN 'fee' ELSE 'interest' END;

  IF v_owed IS DISTINCT FROM NEW.amount_claimed THEN
    SELECT full_name INTO v_name FROM profiles WHERE id = NEW.member_id;
    RAISE EXCEPTION '%''s figure has changed since this was recorded (it was %, it is now %). Nothing was posted — reject this settlement and run it again.',
      COALESCE(v_name, 'A member'), fmt_tzs(NEW.amount_claimed), fmt_tzs(COALESCE(v_owed, 0));
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION guard_settlement_row() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS settlement_row_guard ON payment_submissions;
CREATE TRIGGER settlement_row_guard
  BEFORE UPDATE OF status ON payment_submissions
  FOR EACH ROW EXECUTE FUNCTION guard_settlement_row();

-- --------------------------------------------------------------------------
-- 8. approve_monthly_settlement — the second admin, once.
--
--    Each row goes through approve_submission, unchanged, so the tally, the signature
--    rules and the audit trail are the ones every other payment has, and the guard
--    above applies to each row as it posts: one stale row refuses the whole signature,
--    and the way out is reject_monthly_settlement below.
--
--    A signer's own money, and anything they have already signed, is stepped over
--    rather than refused: it is left for another admin, and left_count says so.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_monthly_settlement(p_batch_id uuid)
RETURNS jsonb AS $$
DECLARE
  v_sub    payment_submissions%ROWTYPE;
  v_signed uuid[] := '{}';
  v_posted uuid[];
  v_total  numeric(14,2) := 0;
  v_left   int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  FOR v_sub IN
    SELECT * FROM payment_submissions
     WHERE settlement_batch_id = p_batch_id AND status = 'pending'
     ORDER BY id
     FOR UPDATE
  LOOP
    CONTINUE WHEN v_sub.member_id = auth.uid() AND NOT is_superadmin();
    CONTINUE WHEN EXISTS (SELECT 1 FROM submission_approvals
                           WHERE submission_id = v_sub.id AND admin_id = auth.uid());

    PERFORM approve_submission(v_sub.id, v_sub.amount_claimed);
    v_signed := v_signed || v_sub.id;
    v_total  := v_total + v_sub.amount_claimed;
  END LOOP;

  IF coalesce(array_length(v_signed, 1), 0) = 0 THEN
    RAISE EXCEPTION 'There is nothing in this settlement for you to sign. Another admin has to.';
  END IF;

  SELECT array_agg(id) INTO v_posted
    FROM payment_submissions WHERE id = ANY(v_signed) AND status = 'approved';
  PERFORM notify_settlement_members(COALESCE(v_posted, '{}'));

  SELECT count(*) INTO v_left FROM payment_submissions
   WHERE settlement_batch_id = p_batch_id AND status = 'pending';

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'approve_monthly_settlement', 'submission', NULL,
          jsonb_build_object(
            'batch_id',     p_batch_id,
            'signed_count', array_length(v_signed, 1),
            'signed_total', v_total,
            'left_count',   v_left
          ));

  RETURN jsonb_build_object(
    'signed_count', array_length(v_signed, 1),
    'signed_total', v_total,
    'left_count',   v_left
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION approve_monthly_settlement(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION approve_monthly_settlement(uuid) TO authenticated;

-- --------------------------------------------------------------------------
-- 9. reject_monthly_settlement — take back whatever is still waiting.
--
--    The rows go back on the sheet. Anything that already posted on one signature
--    stays posted: that is a settled payment, and the way to undo one is a void (037).
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION reject_monthly_settlement(p_batch_id uuid, p_reason text)
RETURNS int AS $$
DECLARE
  v_id    uuid;
  v_count int := 0;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Add a short reason for the rejection.';
  END IF;

  FOR v_id IN
    SELECT id FROM payment_submissions
     WHERE settlement_batch_id = p_batch_id AND status = 'pending'
     ORDER BY id
     FOR UPDATE
  LOOP
    PERFORM reject_submission(v_id, trim(p_reason));
    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'Nothing in that settlement is waiting any more.';
  END IF;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'reject_monthly_settlement', 'submission', NULL,
          jsonb_build_object('batch_id', p_batch_id, 'rejected', v_count, 'reason', trim(p_reason)));

  RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION reject_monthly_settlement(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION reject_monthly_settlement(uuid, text) TO authenticated;

-- --------------------------------------------------------------------------
-- 10. Messages. The body is the amount, which reads the same in both languages, so a
--    NULL template body keeps it (033).
-- --------------------------------------------------------------------------

INSERT INTO notification_templates (kind, lang, title, body) VALUES
  ('settlement_recorded', 'sw', 'Malipo yako ya mwezi yameingizwa', NULL),
  ('settlement_recorded', 'en', 'Your monthly payment was recorded', NULL),
  ('settlement_awaiting_signature', 'sw', 'Malipo ya mwezi yanasubiri saini yako', NULL),
  ('settlement_awaiting_signature', 'en', 'A monthly settlement needs your signature', NULL)
ON CONFLICT (kind, lang) DO UPDATE
  SET title = EXCLUDED.title, body = EXCLUDED.body;
