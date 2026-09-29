-- 044_meeting_day_fee_due_dates.sql — a monthly fee falls due at the meeting too.
--
-- 043 anchored loan installments to the meeting day and deliberately left fees
-- alone. Its reasoning: a fee is due on the last day of its own month, the last
-- Saturday always falls on or before that, so the meeting is already the final
-- collection before the fee turns overdue on the 1st — and moving it would make
-- fees STRICTER rather than fix a bug.
--
-- That reasoning was right about the mechanics and wrong about what the group
-- wants. The group's rule, stated plainly: monthly fee contributions are handed
-- over at the monthly meeting. Nothing is collected between meetings. So the
-- last day of the month is not when the fee is due — it is several days AFTER
-- the only occasion on which it could have been paid:
--
--     period 2026-11-01 -> meeting Sat 2026-11-28 -> old due date Mon 2026-11-30
--     period 2026-12-01 -> meeting Sat 2026-12-26 -> old due date Thu 2026-12-31
--
-- In that gap the app told a member they still had days to pay when in fact
-- their chance had passed, and a member who DID pay at the meeting saw the fee
-- sit as 'pending' afterwards. Anchoring the due date to the meeting makes
-- 'pending' mean "not collected yet", and 'overdue' mean what the group means by
-- it: you were at the meeting, or should have been, and did not pay.
--
-- YES, THIS IS STRICTER, BY 2-5 DAYS A MONTH. A fee now turns overdue on the
-- Sunday after the meeting instead of the 1st of the next month. That is the
-- change the group asked for, and it costs nothing today: penalty_rate has been
-- 0 since the 2026-08-25 opening reset, and penalty_rate is snapshotted per row
-- at creation, so no existing or new fee carries a penalty at all. If the group
-- ever raises the rate, this is the window it applies to — worth saying out loud
-- at the meeting that votes it.
--
-- OCTOBER IS A FREEBIE. The last Saturday of October 2026 IS 2026-10-31, the
-- last day of the month, so the first period under the new rule has exactly the
-- due date it would have had under the old one. November is the first month
-- where the two differ (28th vs 30th).
--
-- SCOPE: PERIODS FROM 2026-10-01 ONWARD. Earlier fees keep the last-day-of-month
-- rule they were raised and collected under. This is the same stance 043 took on
-- installments already written — the due date a member was told is not something
-- a migration gets to rewrite underneath them. The cutover is a literal rather
-- than a setting because it is a historical fact about one group's decision, not
-- a knob; on a fresh database every period is after it, so every fee gets the
-- new rule and the branch costs nothing.
--
-- CREATE OR REPLACE, NOT DROP: the column list and its ordering are unchanged
-- (only the due_date EXPRESSION differs), so replacing in place keeps the grants
-- 021 made and the dependent v_fee_status_money, both of which a DROP ... CASCADE
-- would silently take with it.
--
-- WITH (security_invoker = true) IS LOAD-BEARING, NOT DECORATION. A replace does
-- NOT inherit the view's existing reloptions — it resets them to the defaults, and
-- the default is security_invoker = FALSE, which runs the view as its owner and
-- bypasses the RLS underneath. Leaving it off here reopens precisely the hole 027
-- closed: any member could read every other member's fee rows out of
-- v_fee_status_money. 05_guards.test.sql catches it, and caught it while this
-- migration was being written.
--
-- Requires 043 (meeting_day) and 021 (the view body this rewrites).

CREATE OR REPLACE VIEW v_fee_status WITH (security_invoker = true) AS
WITH b AS (
  SELECT mf.*,
         CASE
           WHEN mf.period >= DATE '2026-10-01'
             THEN meeting_day((mf.period + INTERVAL '1 month' - INTERVAL '1 day')::date)
           ELSE (mf.period + INTERVAL '1 month' - INTERVAL '1 day')::date
         END                                                      AS due_date,
         greatest(mf.amount - mf.amount_paid, 0)                  AS remaining
  FROM monthly_fees mf
)
SELECT
  b.*,
  CASE
    WHEN b.status = 'paid' OR b.remaining <= 0 OR today_eat() <= b.due_date THEN 0
    ELSE (date_part('year',  age(today_eat(), b.due_date)) * 12
        + date_part('month', age(today_eat(), b.due_date)))::int + 1
  END AS penalty_months,
  -- 'overdue' outranks 'partial': being past due is the signal that matters, and
  -- amount_paid > 0 tells the UI to render it as partly settled.
  CASE
    WHEN b.status = 'paid' OR b.remaining <= 0 THEN 'paid'
    WHEN today_eat() > b.due_date              THEN 'overdue'
    WHEN b.amount_paid > 0                     THEN 'partial'
    ELSE 'pending'
  END AS computed_status
FROM b;

-- v_fee_status_money reads due_date and penalty_months straight out of the view
-- above, so it needs no change — but it is worth naming what now follows for
-- free: the daily reminder sweep (026, Swahili bodies in 033) selects on
-- f.due_date, so "your fee is due in 3 days" now counts down to the meeting
-- rather than to the end of the month. That is the message the group wants
-- members to get.
