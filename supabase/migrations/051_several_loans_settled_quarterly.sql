-- 051_several_loans_settled_quarterly.sql — up to three loans at once, and every
-- loan ends at the next quarter-end meeting.
--
-- WHY. Decision #4 said a member may hold one loan at a time. The group does not work
-- that way: what it collects at a meeting is lent straight back out at that meeting,
-- and some of it goes to members who are already borrowing. The rule made that
-- impossible to record ("That member already has a loan in progress").
--
-- THE RULE NOW, as the group set it on 2026-10-31:
--
--   * Up to three loans in progress per member. A pending loan counts.
--   * Every loan ends at the next March, June, September or December meeting, the
--     first loan included, so all the group's lending comes home together.
--   * Interest stays at the group's rate, paid monthly, for only the months the loan
--     actually runs. TSh 110,000 issued at each of these meetings:
--
--       31 Oct 2026   28 Nov 5,500 · 26 Dec 5,500 + 110,000
--       28 Nov 2026   26 Dec 5,500 + 110,000
--       26 Dec 2026   30 Jan 5,500 · 27 Feb 5,500 · 27 Mar 5,500 + 110,000
--
--   * The ceiling covers everything the member owes. The multiple-of-contribution and
--     share-of-assets arms are unchanged, but each is now tested against this loan PLUS
--     the member's outstanding principal. Tested per loan, as it has been, three
--     loans would each be allowed the whole ceiling.
--
-- ONLY ACTIVE LOANS COUNT TOWARDS THE CEILING, not other pending ones. Those have not
-- moved any money, and approve_loan re-checks at every signature, so the second of
-- two pending loans is refused the moment the first has used the room. Each member's
-- profile row is locked for the check, so two approvals at the same instant queue up
-- rather than both reading the old balance.
--
-- SCOPE. Newly approved loans only. Installments already written keep their dates; the
-- loans issued on 26 September already end on 26 December, a quarter-end.
--
-- NOT TOUCHED. Restructuring (022) sets its own term by a two-admin decision, so a
-- rescued loan may run past a quarter-end. Settle the month (049) still takes interest
-- only; principal at quarter-end goes through Record a payment.
--
-- Requires 048 (current approve_loan), 047 (group_member_directory), 049
-- (monthly_settlement_sheet) and 033 (send_due_reminders).

-- --------------------------------------------------------------------------
-- 1. loan_term_months — how many meetings until quarter-end.
--
--    Takes the meeting the loan was issued at. A loan issued AT a quarter-end meeting
--    runs the whole next quarter, not zero months. The JS twin is
--    quarterEndAfter() in src/lib/meetings.js. Change one, change the other.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION loan_term_months(p_anchor date)
RETURNS int AS $$
  SELECT 3 - (EXTRACT(MONTH FROM p_anchor)::int % 3);
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION loan_term_months(date) IS
  'Months from the meeting a loan was issued at to the next March, June, September or December meeting.';

GRANT EXECUTE ON FUNCTION loan_term_months(date) TO authenticated;

-- The setting no longer sets a new loan's term; a restructure still offers it as
-- the default in its form.
UPDATE group_settings
   SET label = 'Default term when restructuring a loan (months)'
 WHERE key = 'default_loan_months';

-- --------------------------------------------------------------------------
-- 2. approve_loan — 048's body, with the ceiling, the term and the loan-free count
--    changed. Marked CHANGED (051).
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_loan(p_loan_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_loan              loans%ROWTYPE;
  v_int               numeric(12,2);
  v_pool              numeric(14,2);
  v_assets            numeric(14,2);
  v_contribution      numeric(14,2);
  v_owed              numeric(14,2);
  v_ceiling           numeric;
  v_owed_note         text;
  v_required          int;
  v_approvals         int;
  v_final_proof       text;
  v_other_admin_loans int;
  v_total_admins      int;
  v_fraction          numeric := setting('pool_loan_fraction');
  v_multiplier        numeric := setting('contribution_multiplier');
  v_rate              numeric := setting('loan_interest_rate');
  v_months            int;
  v_anchor            date;
  v_n                 int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL          THEN RAISE EXCEPTION 'Loan not found';      END IF;
  IF v_loan.status <> 'pending' THEN RAISE EXCEPTION 'Loan is not pending'; END IF;

  -- CHANGED (051): what the member already owes counts against both ceilings.
  PERFORM 1 FROM profiles WHERE id = v_loan.member_id FOR NO KEY UPDATE;
  SELECT COALESCE(SUM(COALESCE(outstanding_principal, principal)), 0) INTO v_owed
    FROM loans WHERE member_id = v_loan.member_id AND status = 'active';

  -- 045: a share of everything the group owns, not of today's cash.
  SELECT total_assets_tzs INTO v_assets FROM v_group_assets;
  v_ceiling := floor(v_fraction * COALESCE(v_assets, 0));
  v_owed_note := CASE WHEN v_owed > 0
                      THEN format(' They already owe %s, so they can borrow at most %s more.',
                                  fmt_tzs(v_owed), fmt_tzs(greatest(v_ceiling - v_owed, 0)))
                      ELSE '' END;
  IF v_loan.principal + v_owed > v_ceiling THEN
    RAISE EXCEPTION 'Loan exceeds % of the group''s total assets (max %).%',
      round(v_fraction * 100) || '%', v_ceiling, v_owed_note;
  END IF;

  -- 045: the cash has to be there.
  SELECT pool_balance_tzs INTO v_pool FROM v_group_pool;
  IF v_loan.principal > COALESCE(v_pool, 0) THEN
    RAISE EXCEPTION 'The pool holds only % — not enough to disburse % today. Wait for repayments.',
      COALESCE(v_pool, 0), v_loan.principal;
  END IF;

  -- 047: the same savings the member is shown, including approved adjustments
  -- and part-paid fees.
  v_contribution := member_savings(v_loan.member_id);
  v_ceiling := floor(v_multiplier * v_contribution);
  v_owed_note := CASE WHEN v_owed > 0
                      THEN format(' They already owe %s, so they can borrow at most %s more.',
                                  fmt_tzs(v_owed), fmt_tzs(greatest(v_ceiling - v_owed, 0)))
                      ELSE '' END;
  IF v_loan.principal + v_owed > v_ceiling THEN
    RAISE EXCEPTION 'Loan exceeds %x member contribution (max %).%',
      v_multiplier, v_ceiling, v_owed_note;
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
    -- CHANGED (051): admins, not loans. With two loans allowed, counting rows would
    -- read one admin's two loans as two admins and refuse a third who is fine.
    SELECT count(DISTINCT member_id) INTO v_other_admin_loans
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

  -- 048: the meeting this loan was issued at. Read once, so every installment on the
  -- loan is counted from the same anchor even if the clock crosses midnight — or a
  -- meeting — mid-loop.
  v_anchor := last_meeting_day(today_eat());
  -- CHANGED (051): to the next quarter-end meeting, not a fixed number of months.
  v_months := loan_term_months(v_anchor);

  FOR v_n IN 1..v_months LOOP
    INSERT INTO loan_installments
      (loan_id, installment_number, due_date, principal_due, interest_due, penalty_rate)
    VALUES (
      p_loan_id,
      v_n,
      -- 048: the n-th meeting after the one the money was handed over at. Adding
      -- months to the anchor first keeps one installment per month even when the day
      -- clamps (31 Jan + 1 month = 28 Feb); meeting_day (043) then moves it to that
      -- month's last Saturday.
      meeting_day((v_anchor + (v_n || ' month')::interval)::date),
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
            'months',        v_months,
            'group_assets',  v_assets,
            'pool',          v_pool,
            'contribution',  v_contribution,
            'already_owed',  v_owed,
            'issued_at_meeting', v_anchor
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- --------------------------------------------------------------------------
-- 3. file_loan — 036's body, with one-loan-at-a-time replaced by three. It locks the
--    same row as approve_loan, so two filings at once cannot make a fourth.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION file_loan(p_member_id uuid, p_principal numeric)
RETURNS uuid AS $$
DECLARE
  v_id        uuid;
  v_name      text;
  c_max_loans CONSTANT int := 3;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_principal IS NULL OR p_principal <= 0 THEN
    RAISE EXCEPTION 'Enter a loan amount greater than zero';
  END IF;
  PERFORM 1 FROM profiles WHERE id = p_member_id FOR NO KEY UPDATE;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_member_id AND is_active = true) THEN
    RAISE EXCEPTION 'That member is not active';
  END IF;
  IF (SELECT count(*) FROM loans
       WHERE member_id = p_member_id AND status IN ('pending', 'active')) >= c_max_loans THEN
    RAISE EXCEPTION 'That member already has % loans in progress', c_max_loans;
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
-- 4. group_member_directory — everything the member owes, not their newest loan.
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
    member_savings(p.id)                       AS savings_tzs,
    COALESCE(ln.outstanding, 0)                AS active_loan_tzs,
    ln.outstanding IS NOT NULL                 AS has_active_loan
  FROM profiles p
  LEFT JOIN LATERAL (
    SELECT SUM(COALESCE(outstanding_principal, principal)) AS outstanding
    FROM loans
    WHERE member_id = p.id AND status = 'active'
  ) ln ON true
  WHERE p.is_active = true
  ORDER BY p.full_name;
$$;

GRANT EXECUTE ON FUNCTION group_member_directory() TO authenticated;

-- --------------------------------------------------------------------------
-- 5. v_loan_risk — also a loan whose principal is overdue.
--
--    "Two overdue installments" assumed every loan had three. A loan issued the month
--    before quarter-end has one, so it could never be flagged however late it ran.
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
HAVING count(i.id) >= 2 OR bool_or(i.principal_remaining > 0);

GRANT SELECT ON v_loan_risk TO authenticated;

-- --------------------------------------------------------------------------
-- 6. monthly_settlement_sheet — each interest row says which loan it belongs to.
--
--    A new column changes the return type, so this has to be a drop. Nothing else
--    calls it: record_monthly_settlement reads settlement_due_rows directly.
-- --------------------------------------------------------------------------

DROP FUNCTION monthly_settlement_sheet();

CREATE FUNCTION monthly_settlement_sheet()
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
  needs_second_signature boolean,
  loan_id                uuid,
  loan_principal         numeric,
  loan_issued_at         timestamptz
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
           END,
           l.id, l.principal::numeric, l.disbursed_at
      FROM settlement_due_rows() d
      LEFT JOIN loan_installments i ON d.kind = 'interest' AND i.id = d.related_id
      LEFT JOIN loans l             ON l.id = i.loan_id
     WHERE NOT d.has_pending
     ORDER BY d.full_name, d.member_id, d.kind, d.due_date, l.principal;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION monthly_settlement_sheet() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION monthly_settlement_sheet() TO authenticated;

-- --------------------------------------------------------------------------
-- 7. send_due_reminders — 033's body, with the loan named in each loan reminder.
--    Each installment is still its own reminder, so a member with two loans due hears
--    twice, and needs to be able to tell them apart.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION send_due_reminders()
RETURNS int AS $$
DECLARE
  r      record;
  v_week text := to_char(today_eat(), 'IYYY-IW');
  v_n    int := 0;
  v_lang text;
  v_title text;
  v_body  text;
BEGIN
  -- Monthly fees: due soon, or already overdue.
  FOR r IN
    SELECT f.member_id, f.id, f.due_date, f.total_with_penalty, f.computed_status
      FROM v_fee_status_money f
     WHERE f.computed_status <> 'paid'
       AND f.remaining > 0
       AND f.due_date <= today_eat() + 3
  LOOP
    v_lang := member_lang(r.member_id);

    IF v_lang = 'en' THEN
      v_title := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Monthly fee overdue' ELSE 'Monthly fee due soon' END;
      v_body  := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Your monthly fee of ' || fmt_tzs(r.total_with_penalty) ||
                           ' is overdue. Pay in the app to stop the penalty growing.'
                      ELSE 'Your monthly fee of ' || fmt_tzs(r.total_with_penalty) ||
                           ' is due on ' || fmt_day(r.due_date) || '.' END;
    ELSE
      v_title := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Ada ya mwezi imechelewa'
                      ELSE 'Ada ya mwezi inakaribia kuisha muda' END;
      v_body  := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Ada yako ya mwezi ya ' || fmt_tzs(r.total_with_penalty) ||
                           ' imechelewa. Lipa kwenye programu ili faini isiongezeke.'
                      ELSE 'Ada yako ya mwezi ya ' || fmt_tzs(r.total_with_penalty) ||
                           ' inatakiwa kulipwa tarehe ' || fmt_day(r.due_date) || '.' END;
    END IF;

    PERFORM enqueue_delivery(r.member_id, v_title, v_body, NULL,
                             'fee:' || r.id || ':' || v_week);
    v_n := v_n + 1;
  END LOOP;

  -- Loan installments: same rule.
  FOR r IN
    SELECT l.member_id, l.principal AS loan_principal,
           i.id, i.due_date, i.total_with_penalty, i.computed_status
      FROM v_installment_status_money i
      JOIN loans l ON l.id = i.loan_id
     WHERE i.computed_status NOT IN ('paid', 'cancelled')
       AND i.remaining > 0
       AND l.status = 'active'
       AND i.due_date <= today_eat() + 3
  LOOP
    v_lang := member_lang(r.member_id);

    IF v_lang = 'en' THEN
      v_title := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Loan repayment overdue' ELSE 'Loan repayment due soon' END;
      v_body  := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Your repayment of ' || fmt_tzs(r.total_with_penalty) ||
                           ' on your loan of ' || fmt_tzs(r.loan_principal) ||
                           ' is overdue. Pay in the app to stop the penalty growing.'
                      ELSE 'Your repayment of ' || fmt_tzs(r.total_with_penalty) ||
                           ' on your loan of ' || fmt_tzs(r.loan_principal) ||
                           ' is due on ' || fmt_day(r.due_date) || '.' END;
    ELSE
      v_title := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Marejesho ya mkopo yamechelewa'
                      ELSE 'Marejesho ya mkopo yanakaribia' END;
      v_body  := CASE WHEN r.computed_status = 'overdue'
                      THEN 'Marejesho yako ya ' || fmt_tzs(r.total_with_penalty) ||
                           ' ya mkopo wa ' || fmt_tzs(r.loan_principal) ||
                           ' yamechelewa. Lipa kwenye programu ili faini isiongezeke.'
                      ELSE 'Marejesho yako ya ' || fmt_tzs(r.total_with_penalty) ||
                           ' ya mkopo wa ' || fmt_tzs(r.loan_principal) ||
                           ' yanatakiwa kulipwa tarehe ' || fmt_day(r.due_date) || '.' END;
    END IF;

    PERFORM enqueue_delivery(r.member_id, v_title, v_body, NULL,
                             'inst:' || r.id || ':' || v_week);
    v_n := v_n + 1;
  END LOOP;

  -- Share-outs waiting to be collected.
  FOR r IN
    SELECT d.member_id, d.id, d.total_payout_tzs
      FROM distributions d
     WHERE d.status = 'pending'
  LOOP
    v_lang := member_lang(r.member_id);

    IF v_lang = 'en' THEN
      v_title := 'Your share-out is waiting';
      v_body  := fmt_tzs(r.total_payout_tzs) || ' is ready for you from the last cycle.';
    ELSE
      v_title := 'Mgao wako unakusubiri';
      v_body  := fmt_tzs(r.total_payout_tzs) || ' iko tayari kwako kutoka mzunguko uliopita.';
    END IF;

    PERFORM enqueue_delivery(r.member_id, v_title, v_body, NULL,
                             'dist:' || r.id || ':' || v_week);
    v_n := v_n + 1;
  END LOOP;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (NULL, 'send_due_reminders', 'system', NULL,
          jsonb_build_object('reminders', v_n, 'week', v_week));

  RETURN v_n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
