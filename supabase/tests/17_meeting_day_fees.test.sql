-- 17_meeting_day_fees.test.sql — monthly fees fall due at the meeting (044).
--
-- The property that matters is the same one 16 asserts for installments: a member
-- can only pay at the monthly meeting, so a fee must not be marked overdue on a
-- date when no meeting has yet given them the chance to pay — and it must not go
-- on claiming to be payable for days after the meeting has passed.
--
-- The second half is what 044 adds over 043's stance: between the last Saturday
-- and the 1st there is a window in which the old rule called a fee 'pending' when
-- the member's only opportunity to pay it had already gone.

DO $$
DECLARE
  v_member uuid;
  v_fee    uuid;
  r        record;
  v_count  int;
BEGIN
  v_member := tests.make_member('Fee Meeting Member');

  -- ============================================== the cutover

  -- Periods before October 2026 keep the last-day-of-month rule they were
  -- collected under. September 2026 ended on Wednesday the 30th.
  v_fee := tests.give_fee(v_member, date '2026-09-01');
  SELECT due_date::text AS d INTO r FROM v_fee_status WHERE id = v_fee;
  PERFORM tests.eq(r.d, '2026-09-30', 'September 2026 keeps the old last-day rule');

  -- October 2026 is the first period under the new rule — and its last Saturday
  -- IS the 31st, so the date is unchanged. The rule moved; this month did not.
  v_fee := tests.give_fee(v_member, date '2026-10-01');
  SELECT due_date::text AS d INTO r FROM v_fee_status WHERE id = v_fee;
  PERFORM tests.eq(r.d, '2026-10-31', 'October 2026: meeting day is also the month end');

  -- November is where the two rules actually diverge: meeting Sat 28th, month
  -- ends Mon 30th. This is the assertion that would fail if 044 were reverted.
  v_fee := tests.give_fee(v_member, date '2026-11-01');
  SELECT due_date::text AS d INTO r FROM v_fee_status WHERE id = v_fee;
  PERFORM tests.eq(r.d, '2026-11-28', 'November 2026 falls due at the meeting, not the 30th');

  v_fee := tests.give_fee(v_member, date '2026-12-01');
  SELECT due_date::text AS d INTO r FROM v_fee_status WHERE id = v_fee;
  PERFORM tests.eq(r.d, '2026-12-26', 'December 2026 falls due at the meeting, not the 31st');

  -- ============================================== the general property

  -- Every fee period from the cutover on is due on a Saturday (DOW 6)...
  INSERT INTO monthly_fees (member_id, period, amount, status)
  SELECT v_member, g::date, 10000, 'pending'
    FROM generate_series('2027-01-01'::date, '2029-12-01'::date, '1 month') g
  ON CONFLICT (member_id, period) DO NOTHING;

  SELECT count(*) INTO v_count
    FROM v_fee_status
   WHERE member_id = v_member
     AND period >= date '2026-10-01'
     AND EXTRACT(DOW FROM due_date) <> 6;
  PERFORM tests.eq(v_count, 0, 'every fee from the cutover falls due on a Saturday');

  -- ...specifically its own month's meeting, never a neighbouring month's.
  SELECT count(*) INTO v_count
    FROM v_fee_status
   WHERE member_id = v_member
     AND period >= date '2026-10-01'
     AND (due_date <> meeting_day(due_date)
          OR date_trunc('month', due_date) <> date_trunc('month', period));
  PERFORM tests.eq(v_count, 0, 'every fee falls due at its own month''s meeting');

  -- ...and never AFTER the month it belongs to, which would let a fee outlive
  -- the period it is charged for.
  SELECT count(*) INTO v_count
    FROM v_fee_status
   WHERE member_id = v_member
     AND period >= date '2026-10-01'
     AND due_date > (period + INTERVAL '1 month' - INTERVAL '1 day')::date;
  PERFORM tests.eq(v_count, 0, 'no fee is due after the end of its own month');

  -- ============================================== paid short-circuits

  -- A settled fee is 'paid' and accrues no penalty whatever its due date does.
  UPDATE monthly_fees SET status = 'paid', amount_paid = amount
   WHERE member_id = v_member AND period = date '2026-11-01';
  SELECT computed_status AS s, penalty_months AS p INTO r
    FROM v_fee_status WHERE member_id = v_member AND period = date '2026-11-01';
  PERFORM tests.eq(r.s, 'paid',  'a settled fee reads paid');
  PERFORM tests.eq(r.p, 0,       'a settled fee accrues no penalty months');

  -- ============================================== the view survived intact
  --
  -- 044 uses CREATE OR REPLACE precisely so the security_invoker flag 027 set and
  -- the dependent money view both survive. Assert it rather than trust it: a
  -- future edit that reaches for DROP ... CASCADE would drop both silently.

  SELECT count(*) INTO v_count
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'v_fee_status'
     AND c.reloptions @> ARRAY['security_invoker=true'];
  PERFORM tests.eq(v_count, 1, 'v_fee_status still has security_invoker set');

  SELECT count(*) INTO v_count
    FROM pg_views WHERE schemaname = 'public' AND viewname = 'v_fee_status_money';
  PERFORM tests.eq(v_count, 1, 'v_fee_status_money survived the replace');

  -- The money view must be reading the NEW due date, not a stale copy.
  SELECT due_date::text AS d INTO r
    FROM v_fee_status_money WHERE member_id = v_member AND period = date '2026-12-01';
  PERFORM tests.eq(r.d, '2026-12-26', 'the money view carries the meeting-day due date');

  RAISE NOTICE 'meeting day / fee due date tests passed';
END $$;
