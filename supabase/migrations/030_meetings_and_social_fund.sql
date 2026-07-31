-- 030_meetings_and_social_fund.sql — the two structures every VICOBA has that
-- this app did not model at all.
--
-- 1. MEETINGS AND ATTENDANCE. The group meets monthly; that is where loans get
--    agreed and rules get voted on. Attendance fines are a normal revenue line and
--    the main thing that keeps a meeting quorate.
--
--    Fines are DEDUCTED, not invoiced. A fine writes a negative savings_adjustments
--    row plus a positive earnings_ledger row, so it flows straight into the
--    member's balance, the transparency directory, the pool and the cycle
--    share-out with no new plumbing — and approve_submission is not touched a
--    fourth time. Fine amounts are group_settings keys, so they change by the same
--    2-of-N vote as every other rule.
--
-- 2. SOCIAL FUND (bima ya jamii). A separate pot for funerals and medical
--    emergencies. Deliberately OUTSIDE v_group_pool: it is welfare money, not
--    loanable capital, and folding it in would silently raise every member's loan
--    ceiling (the cap is a fraction of the pool). Kept separate, it also cannot be
--    lent out by accident.
--
-- Requires 020 (settings), 021 (earnings_ledger).

-- --------------------------------------------------------------------------
-- 1. Fine amounts as group rules
-- --------------------------------------------------------------------------

INSERT INTO group_settings (key, value, min_value, max_value, label) VALUES
  ('attendance_fine_late',   1000, 0, 100000, 'Fine for arriving late'),
  ('attendance_fine_absent', 2000, 0, 100000, 'Fine for missing a meeting')
ON CONFLICT (key) DO NOTHING;

-- --------------------------------------------------------------------------
-- 2. Meetings and the register
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS meetings (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  held_on    date NOT NULL,
  title      text NOT NULL,
  minutes    text,
  cycle_id   uuid REFERENCES cycles(id) ON DELETE SET NULL,
  -- Fines only bite once. Recording the register is reversible; applying the
  -- fines is not, so it is a separate, explicit step.
  fines_applied_at timestamptz,
  created_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS meetings_held_on_idx ON meetings (held_on DESC);

CREATE TABLE IF NOT EXISTS meeting_attendance (
  meeting_id uuid NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  member_id  uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  status     text NOT NULL DEFAULT 'present'
               CHECK (status IN ('present', 'late', 'excused', 'absent')),
  fine_tzs   numeric(12,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (meeting_id, member_id)
);

ALTER TABLE meetings           ENABLE ROW LEVEL SECURITY;
ALTER TABLE meeting_attendance ENABLE ROW LEVEL SECURITY;

-- Minutes and the register are the group's record; everyone reads them.
DROP POLICY IF EXISTS "Everyone reads meetings" ON meetings;
CREATE POLICY "Everyone reads meetings" ON meetings
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Everyone reads attendance" ON meeting_attendance;
CREATE POLICY "Everyone reads attendance" ON meeting_attendance
  FOR SELECT USING (auth.uid() IS NOT NULL);

GRANT SELECT ON meetings, meeting_attendance TO authenticated;

-- --------------------------------------------------------------------------
-- 3. Recording a meeting
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION record_meeting(
  p_held_on date, p_title text, p_minutes text DEFAULT NULL
)
RETURNS uuid AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(trim(p_title), '') = '' THEN RAISE EXCEPTION 'Give the meeting a title'; END IF;
  IF p_held_on > today_eat() THEN RAISE EXCEPTION 'A meeting cannot be recorded in the future'; END IF;

  INSERT INTO meetings (held_on, title, minutes, created_by, cycle_id)
  VALUES (p_held_on, trim(p_title), NULLIF(trim(p_minutes), ''), auth.uid(),
          (SELECT id FROM cycles WHERE status = 'open' LIMIT 1))
  RETURNING id INTO v_id;

  -- Everyone starts present; the admin marks the exceptions. In a 15-member group
  -- that is far less tapping than the other way round.
  INSERT INTO meeting_attendance (meeting_id, member_id, status)
  SELECT v_id, p.id, 'present' FROM profiles p WHERE p.is_active = true;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'record_meeting', 'meeting', v_id,
          jsonb_build_object('held_on', p_held_on, 'title', p_title));

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION set_attendance(
  p_meeting_id uuid, p_member_id uuid, p_status text
)
RETURNS void AS $$
DECLARE
  v_applied timestamptz;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_status NOT IN ('present', 'late', 'excused', 'absent') THEN
    RAISE EXCEPTION 'Unknown attendance status: %', p_status;
  END IF;

  SELECT fines_applied_at INTO v_applied FROM meetings WHERE id = p_meeting_id;
  IF v_applied IS NOT NULL THEN
    RAISE EXCEPTION 'The fines for this meeting have already been applied';
  END IF;

  INSERT INTO meeting_attendance (meeting_id, member_id, status)
  VALUES (p_meeting_id, p_member_id, p_status)
  ON CONFLICT (meeting_id, member_id) DO UPDATE SET status = EXCLUDED.status;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION update_meeting_minutes(p_meeting_id uuid, p_minutes text)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE meetings SET minutes = NULLIF(trim(p_minutes), '') WHERE id = p_meeting_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 4. Applying the fines — once, and irreversibly.
--
--    Each fine is a negative savings adjustment (the member's balance falls) plus
--    a positive earnings entry (the group's income rises). That is the same pair
--    022 uses for a loan recovery, and it means the fine reaches the pool, the
--    directory and the share-out with no code that knows what a fine is.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION apply_attendance_fines(p_meeting_id uuid)
RETURNS numeric AS $$
DECLARE
  v_meeting meetings%ROWTYPE;
  v_late    numeric := setting('attendance_fine_late');
  v_absent  numeric := setting('attendance_fine_absent');
  v_total   numeric := 0;
  r         record;
  v_fine    numeric;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF v_meeting.id IS NULL THEN RAISE EXCEPTION 'Meeting not found'; END IF;
  IF v_meeting.fines_applied_at IS NOT NULL THEN
    RAISE EXCEPTION 'The fines for this meeting have already been applied';
  END IF;

  FOR r IN
    SELECT * FROM meeting_attendance WHERE meeting_id = p_meeting_id
  LOOP
    -- 'excused' is the whole point of having four statuses rather than two: a
    -- member who sent word is not fined.
    v_fine := CASE r.status
                WHEN 'late'   THEN v_late
                WHEN 'absent' THEN v_absent
                ELSE 0
              END;

    IF v_fine > 0 THEN
      INSERT INTO savings_adjustments
        (target_member_id, requested_by, delta, reason, status, applied_at)
      VALUES (r.member_id, auth.uid(), -v_fine,
              'Attendance fine: ' || v_meeting.title || ' (' || r.status || ')',
              'approved', now());

      INSERT INTO earnings_ledger (member_id, kind, amount, source_type, source_id)
      VALUES (r.member_id, 'penalty', v_fine, 'meeting', p_meeting_id);

      UPDATE meeting_attendance SET fine_tzs = v_fine
       WHERE meeting_id = p_meeting_id AND member_id = r.member_id;

      INSERT INTO notifications (recipient_id, kind, title, body, data)
      VALUES (r.member_id, 'attendance_fine', 'Attendance fine',
              v_fine || ' TZS was deducted from your savings for ' ||
                CASE r.status WHEN 'late' THEN 'arriving late to ' ELSE 'missing ' END ||
                v_meeting.title || '.',
              jsonb_build_object('meeting_id', p_meeting_id));

      v_total := v_total + v_fine;
    END IF;
  END LOOP;

  UPDATE meetings SET fines_applied_at = now() WHERE id = p_meeting_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'apply_attendance_fines', 'meeting', p_meeting_id,
          jsonb_build_object('total', v_total, 'late', v_late, 'absent', v_absent));

  RETURN v_total;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 5. v_group_pool — a fine moves ownership, not cash.
--
--    NO CASH MOVES WHEN A FINE IS LEVIED. The money is already sitting in the
--    pool as the member's savings; the fine only changes whose it is — the
--    member's capital falls and the group's earnings rise by the same amount.
--
--    But the negative savings_adjustments row a fine writes is, on its own, read
--    by v_group_pool as cash leaving. Without an offsetting term the pool would
--    drop by every fine ever levied while retained earnings rose by the same
--    amount, so assets and claims would drift apart by the total fines collected
--    and v_pool_reconciliation would (correctly) report the books as broken.
--
--    Same fix as loan_recoveries in 022, for the same reason.
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
-- 6. Social fund — a separate pot.
--
--    Contributions and grants are tracked here and NOWHERE in v_group_pool. It is
--    welfare money: not lendable, not part of anyone's loan ceiling, and not
--    shared out at the end of a cycle.
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS social_fund_entries (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id   uuid REFERENCES profiles(id) ON DELETE SET NULL,
  kind        text NOT NULL CHECK (kind IN ('contribution', 'grant')),
  amount      numeric(12,2) NOT NULL CHECK (amount > 0),
  reason      text NOT NULL,
  recorded_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
  proof_url   text,
  occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS social_fund_entries_kind_idx ON social_fund_entries (kind, occurred_at DESC);

CREATE TABLE IF NOT EXISTS social_fund_grant_requests (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  amount       numeric(12,2) NOT NULL CHECK (amount > 0),
  reason       text NOT NULL,
  status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'rejected')),
  requested_by uuid REFERENCES profiles(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  applied_at   timestamptz
);

CREATE TABLE IF NOT EXISTS social_fund_grant_approvals (
  request_id  uuid NOT NULL REFERENCES social_fund_grant_requests(id) ON DELETE CASCADE,
  admin_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, admin_id)
);

ALTER TABLE social_fund_entries         ENABLE ROW LEVEL SECURITY;
ALTER TABLE social_fund_grant_requests  ENABLE ROW LEVEL SECURITY;
ALTER TABLE social_fund_grant_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Everyone reads social fund" ON social_fund_entries;
CREATE POLICY "Everyone reads social fund" ON social_fund_entries
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Everyone reads grant requests" ON social_fund_grant_requests;
CREATE POLICY "Everyone reads grant requests" ON social_fund_grant_requests
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Admins read grant approvals" ON social_fund_grant_approvals;
CREATE POLICY "Admins read grant approvals" ON social_fund_grant_approvals
  FOR SELECT USING (is_admin());

GRANT SELECT ON social_fund_entries, social_fund_grant_requests,
                social_fund_grant_approvals TO authenticated;

CREATE OR REPLACE VIEW v_social_fund AS
SELECT
  COALESCE(SUM(amount) FILTER (WHERE kind = 'contribution'), 0) AS contributed_tzs,
  COALESCE(SUM(amount) FILTER (WHERE kind = 'grant'), 0)        AS granted_tzs,
  COALESCE(SUM(amount) FILTER (WHERE kind = 'contribution'), 0)
    - COALESCE(SUM(amount) FILTER (WHERE kind = 'grant'), 0)    AS balance_tzs
FROM social_fund_entries;

GRANT SELECT ON v_social_fund TO authenticated;

CREATE OR REPLACE FUNCTION record_social_contribution(
  p_member_id uuid, p_amount numeric, p_reason text, p_proof_url text DEFAULT NULL
)
RETURNS uuid AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Enter an amount'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN RAISE EXCEPTION 'A reason is required'; END IF;

  INSERT INTO social_fund_entries (member_id, kind, amount, reason, recorded_by, proof_url)
  VALUES (p_member_id, 'contribution', p_amount, trim(p_reason), auth.uid(), p_proof_url)
  RETURNING id INTO v_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'social_contribution', 'social_fund', v_id,
          jsonb_build_object('member_id', p_member_id, 'amount', p_amount));

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Paying out of the social fund is 2-of-N like every other outflow.
CREATE OR REPLACE FUNCTION request_social_grant(
  p_member_id uuid, p_amount numeric, p_reason text
)
RETURNS uuid AS $$
DECLARE
  v_id       uuid;
  v_balance  numeric;
  v_others   int;
  v_name     text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Enter an amount'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN RAISE EXCEPTION 'A reason is required'; END IF;

  SELECT balance_tzs INTO v_balance FROM v_social_fund;
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'The social fund holds only %', v_balance;
  END IF;

  INSERT INTO social_fund_grant_requests (member_id, amount, reason, requested_by)
  VALUES (p_member_id, p_amount, trim(p_reason), auth.uid())
  RETURNING id INTO v_id;

  SELECT full_name INTO v_name FROM profiles WHERE id = p_member_id;
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT p.id, 'social_grant_requested', 'Social fund grant proposed',
         p_amount || ' TZS for ' || COALESCE(v_name, 'a member') || ': ' || p_reason,
         jsonb_build_object('request_id', v_id)
    FROM profiles p
   WHERE p.role = 'admin' AND p.is_active = true AND p.id <> auth.uid();

  SELECT COALESCE(count(*), 0) INTO v_others
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> auth.uid();
  IF least(2, v_others) = 0 THEN
    PERFORM execute_social_grant(v_id);
  END IF;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION execute_social_grant(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_req     social_fund_grant_requests%ROWTYPE;
  v_balance numeric;
BEGIN
  SELECT * INTO v_req FROM social_fund_grant_requests WHERE id = p_request_id FOR UPDATE;
  IF v_req.id IS NULL          THEN RAISE EXCEPTION 'Grant request not found'; END IF;
  IF v_req.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';       END IF;

  SELECT balance_tzs INTO v_balance FROM v_social_fund;
  IF v_req.amount > v_balance THEN
    RAISE EXCEPTION 'The social fund holds only %', v_balance;
  END IF;

  INSERT INTO social_fund_entries (member_id, kind, amount, reason, recorded_by)
  VALUES (v_req.member_id, 'grant', v_req.amount, v_req.reason, auth.uid());

  UPDATE social_fund_grant_requests
     SET status = 'approved', applied_at = now() WHERE id = p_request_id;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), 'social_grant', 'social_fund', p_request_id,
          jsonb_build_object('member_id', v_req.member_id, 'amount', v_req.amount));

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  VALUES (v_req.member_id, 'social_grant_approved', 'Social fund grant approved',
          v_req.amount || ' TZS has been granted to you from the social fund.',
          jsonb_build_object('request_id', p_request_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION approve_social_grant(p_request_id uuid)
RETURNS void AS $$
DECLARE
  v_req       social_fund_grant_requests%ROWTYPE;
  v_approvals int;
  v_others    int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_req FROM social_fund_grant_requests WHERE id = p_request_id FOR UPDATE;
  IF v_req.id IS NULL          THEN RAISE EXCEPTION 'Grant request not found'; END IF;
  IF v_req.status <> 'pending' THEN RAISE EXCEPTION 'Already processed';       END IF;
  IF v_req.requested_by = auth.uid() THEN
    RAISE EXCEPTION 'You cannot approve your own request';
  END IF;

  BEGIN
    INSERT INTO social_fund_grant_approvals (request_id, admin_id)
    VALUES (p_request_id, auth.uid());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'You have already approved this grant';
  END;

  SELECT COALESCE(count(*), 0) INTO v_others
    FROM profiles WHERE role = 'admin' AND is_active = true AND id <> v_req.requested_by;
  SELECT count(*) INTO v_approvals
    FROM social_fund_grant_approvals WHERE request_id = p_request_id;

  IF v_approvals < least(2, v_others) THEN RETURN; END IF;

  PERFORM execute_social_grant(p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION reject_social_grant(p_request_id uuid)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE social_fund_grant_requests SET status = 'rejected'
   WHERE id = p_request_id AND status = 'pending';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
