-- 009_notifications.sql — in-app notifications (Phase 4).
-- Triggers insert a row per recipient when something they care about happens:
--   * Member's submission / loan changes status (approved, rejected, loan active/closed)
--   * Admin queue: a new pending submission or loan arrives
-- Members read & dismiss their own rows; the bell + realtime subscription in the
-- frontend surfaces the count without polling.

CREATE TABLE IF NOT EXISTS notifications (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  kind         text NOT NULL,
  title        text NOT NULL,
  body         text,
  data         jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  read_at      timestamptz
);

CREATE INDEX IF NOT EXISTS notifications_recipient_idx
  ON notifications (recipient_id, created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_unread_idx
  ON notifications (recipient_id) WHERE read_at IS NULL;

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Members read own notifications" ON notifications;
CREATE POLICY "Members read own notifications" ON notifications FOR SELECT
  USING (recipient_id = auth.uid());

DROP POLICY IF EXISTS "Members mark own notifications" ON notifications;
CREATE POLICY "Members mark own notifications" ON notifications FOR UPDATE
  USING (recipient_id = auth.uid())
  WITH CHECK (recipient_id = auth.uid());

GRANT SELECT, UPDATE ON notifications TO authenticated;

-- ---------------------------------------------------------------------------
-- Trigger: payment_submissions status change → notify the member
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION notify_on_submission_change()
RETURNS trigger AS $$
DECLARE
  v_type_label text;
BEGIN
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;

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

DROP TRIGGER IF EXISTS on_submission_status_change ON payment_submissions;
CREATE TRIGGER on_submission_status_change
  AFTER UPDATE OF status ON payment_submissions
  FOR EACH ROW EXECUTE FUNCTION notify_on_submission_change();

-- ---------------------------------------------------------------------------
-- Trigger: loan status change → notify the borrower
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION notify_on_loan_change()
RETURNS trigger AS $$
DECLARE
  v_kind  text;
  v_title text;
  v_body  text;
BEGIN
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;

  IF NEW.status = 'active' THEN
    v_kind  := 'loan_active';
    v_title := 'Loan approved';
    v_body  := 'Your loan has been disbursed. Repayment schedule is in your dashboard.';
  ELSIF NEW.status = 'rejected' THEN
    v_kind  := 'loan_rejected';
    v_title := 'Loan request rejected';
    v_body  := COALESCE(NEW.rejection_reason, 'Your loan request was rejected.');
  ELSIF NEW.status = 'closed' THEN
    v_kind  := 'loan_closed';
    v_title := 'Loan fully repaid';
    v_body  := 'Congratulations — your loan has been fully repaid.';
  ELSE
    RETURN NEW;
  END IF;

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (NEW.member_id, v_kind, v_title, v_body,
          jsonb_build_object('loan_id', NEW.id, 'principal', NEW.principal));
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS on_loan_status_change ON loans;
CREATE TRIGGER on_loan_status_change
  AFTER UPDATE OF status ON loans
  FOR EACH ROW EXECUTE FUNCTION notify_on_loan_change();

-- ---------------------------------------------------------------------------
-- Trigger: new pending submission → notify every active admin
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION notify_admins_on_new_submission()
RETURNS trigger AS $$
DECLARE
  v_member_name text;
BEGIN
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

DROP TRIGGER IF EXISTS on_new_submission ON payment_submissions;
CREATE TRIGGER on_new_submission
  AFTER INSERT ON payment_submissions
  FOR EACH ROW EXECUTE FUNCTION notify_admins_on_new_submission();

-- ---------------------------------------------------------------------------
-- Trigger: new pending loan → notify every active admin
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION notify_admins_on_new_loan()
RETURNS trigger AS $$
DECLARE
  v_member_name text;
BEGIN
  SELECT full_name INTO v_member_name FROM profiles WHERE id = NEW.member_id;
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'new_loan',
         'New loan request',
         COALESCE(v_member_name, 'A member') || ' requested ' || NEW.principal || ' TZS',
         jsonb_build_object('loan_id', NEW.id, 'member_id', NEW.member_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS on_new_loan ON loans;
CREATE TRIGGER on_new_loan
  AFTER INSERT ON loans
  FOR EACH ROW EXECUTE FUNCTION notify_admins_on_new_loan();
