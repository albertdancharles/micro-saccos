-- 048_schedule_anchored_to_the_meeting.sql — the repayment schedule counts from
-- the meeting the loan was issued at, not from the day it was typed in.
--
-- THE BUG. 043 fixed WHICH DAY an installment falls on: the last Saturday, the
-- day the group actually meets. It did not fix WHICH MONTH, and the month still
-- comes from `today_eat()` — the moment an admin presses approve:
--
--     meeting_day((today_eat() + (v_n || ' month')::interval)::date)
--
-- The money, though, does not leave on that day. It leaves at the meeting, in
-- the room, by the group's own rule: loans are agreed and handed over on the
-- last Saturday and nowhere else. The approval in the app is a RECORDING of
-- that, and a recording lags — by a day, by a weekend, by whenever the admin
-- next sat down with the register. Every day of that lag pushes the whole
-- schedule a month out, because `today + 1 month` has already left the month of
-- the meeting that is about to happen:
--
--     agreed and disbursed  Sat 2026-09-26   (the meeting)
--     recorded in the app       2026-10-01   (five days later)
--       inst 1  meeting_day(2026-11-01) -> 2026-11-28   the NOVEMBER meeting
--       inst 2                          -> 2026-12-26
--       inst 3                          -> 2027-01-30
--
-- The October meeting is skipped entirely. Thirteen members arrive on 31 October
-- with a month's interest in hand and the app does not ask them for it; the
-- group waits an extra month for its first repayment on 3,932,700 of lending;
-- and a three-month loan runs across four meetings and closes in January.
-- Nobody voted for any of that — it is the lag between the meeting and the
-- paperwork, turned into a month of credit.
--
-- It is not a rounding error either way: ONE FULL MEETING is gained or lost, and
-- it is lost on every loan recorded after its meeting, which is most of them.
--
-- THE FIX. Count from the meeting, not from the keyboard. The meeting a loan was
-- issued at is the last meeting on or before the approval — `last_meeting_day()`
-- below — and installment n falls at the n-th meeting after it:
--
--     recorded 2026-09-26 (at the meeting) -> anchor 2026-09-26 -> inst 1 2026-10-31
--     recorded 2026-10-01 (five days later)-> anchor 2026-09-26 -> inst 1 2026-10-31
--     recorded 2026-10-29 (a month later)  -> anchor 2026-09-26 -> inst 1 2026-10-31
--
-- Said the other way round, which is the property worth holding on to: THE FIRST
-- INSTALLMENT IS ALWAYS THE VERY NEXT MEETING, wherever in the cycle the
-- approval happens to be entered. Before this, it was always the meeting after
-- that.
--
-- WHY NOT ANCHOR FORWARD, to the next meeting after the approval? It gives the
-- same answer in every case above and is one function shorter. It is not used
-- because it is right for the wrong reason: it re-derives the schedule from the
-- paperwork date and happens to agree while the paperwork follows the meeting
-- closely. The anchor here names the thing that actually happened — the meeting
-- where the cash changed hands — so the arithmetic stays correct however late
-- the recording is.
--
-- THE ONE CASE IT GETS WRONG, stated plainly. A loan whose money genuinely left
-- BETWEEN meetings — say handed over on Friday 30 October, recorded the same day
-- — anchors to 26 September and falls due the next morning, 31 October. The
-- group does not lend between meetings, which is why this is acceptable; if it
-- ever does, that loan's schedule must be set by hand, exactly as the September
-- batch is restated by hand in
-- operations/2026-10-01_loans_reanchored_to_the_26_sep_meeting.sql. The old rule
-- had no such case, but paid for it with a skipped meeting on every ordinary
-- loan, which is the trade this migration makes deliberately.
--
-- SCOPE. NEWLY approved loans only. Installments already written keep their
-- dates — the loans recorded for the 26 September meeting are restated by the
-- operations file above, where the group can read the before and after and say
-- yes to it, rather than silently on deploy.
--
-- NOT TOUCHED: monthly fees. A fee belongs to its own month and 044 already
-- anchors it to that month's meeting; it has no approval date to drift from.
--
-- Requires 047 (current approve_loan) and 043 (meeting_day).

-- --------------------------------------------------------------------------
-- 1. last_meeting_day — the meeting a loan issued on p_in was issued at.
--
--    This month's meeting if it has already happened (or is today), otherwise
--    last month's. The JS twin is lastMeetingOnOrBefore() in src/lib/meetings.js,
--    which has computed exactly this since 043 to fill in the date field when an
--    admin records a meeting — the same question, asked by the other half of the
--    app. Change one, change the other.
--
--    IMMUTABLE: depends only on its argument, like meeting_day itself.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION last_meeting_day(p_in date)
RETURNS date AS $$
  SELECT CASE
           WHEN meeting_day(p_in) <= p_in THEN meeting_day(p_in)
           -- The last day of the previous month, which meeting_day then steps
           -- back to that month's last Saturday. Crosses a year end on its own.
           ELSE meeting_day((date_trunc('month', p_in::timestamp) - INTERVAL '1 day')::date)
         END;
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION last_meeting_day(date) IS
  'The most recent meeting on or before p_in: this month''s last Saturday if it has passed, else last month''s.';

GRANT EXECUTE ON FUNCTION last_meeting_day(date) TO authenticated;

-- --------------------------------------------------------------------------
-- 2. approve_loan — 047's body, with the one due_date expression changed.
--    Every ceiling, the 2-of-N tally, the admin mandate, the interest
--    arithmetic and the audit row are byte-for-byte 047.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION approve_loan(p_loan_id uuid, p_proof_url text)
RETURNS void AS $$
DECLARE
  v_loan              loans%ROWTYPE;
  v_int               numeric(12,2);
  v_pool              numeric(14,2);
  v_assets            numeric(14,2);
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
  v_anchor            date;
  v_n                 int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL          THEN RAISE EXCEPTION 'Loan not found';      END IF;
  IF v_loan.status <> 'pending' THEN RAISE EXCEPTION 'Loan is not pending'; END IF;

  -- 045: a share of everything the group owns, not of today's cash.
  SELECT total_assets_tzs INTO v_assets FROM v_group_assets;
  IF v_loan.principal > floor(v_fraction * COALESCE(v_assets, 0)) THEN
    RAISE EXCEPTION 'Loan exceeds % of the group''s total assets (max %).',
      round(v_fraction * 100) || '%', floor(v_fraction * COALESCE(v_assets, 0));
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

  -- CHANGED (048): the meeting this loan was issued at. Read once, so every
  -- installment on the loan is counted from the same anchor even if the clock
  -- crosses midnight — or a meeting — mid-loop.
  v_anchor := last_meeting_day(today_eat());

  FOR v_n IN 1..v_months LOOP
    INSERT INTO loan_installments
      (loan_id, installment_number, due_date, principal_due, interest_due, penalty_rate)
    VALUES (
      p_loan_id,
      v_n,
      -- CHANGED (048): the n-th meeting after the one the money was handed over
      -- at, not the n-th month after the day this was typed in. Adding months to
      -- the anchor first keeps one installment per month even when the day
      -- clamps (31 Jan + 1 month = 28 Feb); meeting_day (043) then moves it to
      -- that month's last Saturday.
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
            -- 048: the meeting the schedule was counted from, so a later
            -- question about a due date does not have to guess at it.
            'issued_at_meeting', v_anchor
          ));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
