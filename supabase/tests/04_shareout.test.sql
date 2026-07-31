-- 04_shareout.test.sql — cycles, time-weighted basis, and the rounding invariant
-- (migrations 023–024).
--
-- Two properties the group's trust rests on:
--
--   1. TIME WEIGHTING. A member who joins in month 11 must not take the same share
--      as one who carried the group from month 1. Weighting by closing balance —
--      the obvious implementation — gets this exactly wrong.
--   2. EVERY SHILLING IS DISTRIBUTED. Largest-remainder rounding means the shares
--      sum to the pot precisely. A naive floor loses shillings; a naive round can
--      overspend it.
--
-- Mirrors src/lib/shareOut.test.js, including the zero-basis case that suite caught.

DO $$
DECLARE
  v_admin   uuid;
  v_early   uuid;
  v_late    uuid;
  v_cycle   uuid;
  v_start   date := DATE '2025-01-01';
  v_end     date := DATE '2025-12-31';
  v_total   numeric;
  v_early_share numeric;
  v_late_share  numeric;
  v_pot     numeric;
  v_closure uuid;
  v_loan    uuid;
BEGIN
  v_admin := tests.make_admin('Cycle Admin');
  v_early := tests.make_member('Early Bird');
  v_late  := tests.make_member('Late Joiner');

  SELECT id INTO v_cycle FROM cycles WHERE status = 'open';
  IF v_cycle IS NULL THEN RAISE EXCEPTION 'migration 023 should seed one open cycle'; END IF;

  PERFORM tests.as_user(v_admin);
  PERFORM update_cycle_dates(v_cycle, v_start, v_end, 'Test Cycle');
  PERFORM tests.as_owner();

  -- Identical amounts, eleven months apart.
  PERFORM tests.give_savings(v_early, 100000, TIMESTAMPTZ '2025-01-05 10:00+03');
  PERFORM tests.give_savings(v_late,  100000, TIMESTAMPTZ '2025-12-05 10:00+03');

  -- ============================================== time-weighted basis
  -- 12 month-end measurements: Early is counted at all 12, Late only at the last.
  PERFORM tests.eq((SELECT basis FROM member_cycle_basis(v_cycle) WHERE member_id = v_early),
    1200000, 'a full-year member accrues 12 member-months');
  PERFORM tests.eq((SELECT basis FROM member_cycle_basis(v_cycle) WHERE member_id = v_late),
    100000, 'a month-11 joiner accrues one');

  -- The admin holds no capital and must therefore have no claim.
  PERFORM tests.eq((SELECT basis FROM member_cycle_basis(v_cycle) WHERE member_id = v_admin),
    0, 'a member who contributed nothing has no basis');

  -- ============================================== earnings for the cycle
  INSERT INTO earnings_ledger (member_id, kind, amount, occurred_at)
  VALUES (v_early, 'interest', 100000, TIMESTAMPTZ '2025-06-01 10:00+03'),
         (v_late,  'penalty',   30000, TIMESTAMPTZ '2025-07-01 10:00+03');

  -- Dated OUTSIDE the window — must not be counted.
  INSERT INTO earnings_ledger (member_id, kind, amount, occurred_at)
  VALUES (v_early, 'interest', 999999, TIMESTAMPTZ '2024-06-01 10:00+03');

  PERFORM tests.eq((SELECT net_tzs FROM cycle_earnings(v_cycle)), 130000,
    'only earnings inside the cycle window count');

  -- ============================================== the split
  SELECT earnings_tzs INTO v_early_share FROM preview_cycle_close(v_cycle, 'earnings_only')
   WHERE member_id = v_early;
  SELECT earnings_tzs INTO v_late_share FROM preview_cycle_close(v_cycle, 'earnings_only')
   WHERE member_id = v_late;

  PERFORM tests.eq(v_early_share, 120000, 'the full-year member takes 12/13 of the pot');
  PERFORM tests.eq(v_late_share,   10000, 'the late joiner takes 1/13');

  -- Equal balances, wildly unequal shares — this is the whole point.
  IF v_early_share <= v_late_share * 10 THEN
    RAISE EXCEPTION 'time weighting is not being applied: % vs %', v_early_share, v_late_share;
  END IF;

  SELECT SUM(earnings_tzs) INTO v_total FROM preview_cycle_close(v_cycle, 'earnings_only');
  PERFORM tests.eq(v_total, 130000, 'shares sum exactly to the pot');

  -- ============================================== rounding, awkward pots
  -- 130,000 divides cleanly; these do not. The invariant must hold regardless.
  FOREACH v_pot IN ARRAY ARRAY[1, 2, 7, 999, 100001, 88888]::numeric[] LOOP
    DELETE FROM earnings_ledger WHERE occurred_at BETWEEN v_start AND v_end + 1;
    INSERT INTO earnings_ledger (member_id, kind, amount, occurred_at)
    VALUES (v_early, 'interest', v_pot, TIMESTAMPTZ '2025-06-01 10:00+03');

    SELECT SUM(earnings_tzs) INTO v_total FROM preview_cycle_close(v_cycle, 'earnings_only');
    PERFORM tests.eq(v_total, v_pot,
      format('largest-remainder distributes every shilling of a %s pot', v_pot));
  END LOOP;

  -- ============================================== a loss year
  DELETE FROM earnings_ledger WHERE occurred_at BETWEEN v_start AND v_end + 1;
  INSERT INTO earnings_ledger (member_id, kind, amount, occurred_at)
  VALUES (v_early, 'write_off', -50000, TIMESTAMPTZ '2025-06-01 10:00+03');

  SELECT COALESCE(SUM(earnings_tzs), 0) INTO v_total
    FROM preview_cycle_close(v_cycle, 'earnings_only');
  PERFORM tests.eq(v_total, 0,
    'a loss is absorbed by the pool, never billed back to members');

  -- ============================================== nobody contributed
  -- Zero total basis must pay nothing. Without the guard the remainder pass hands
  -- shillings to members with no claim at all.
  DELETE FROM earnings_ledger;
  DELETE FROM payment_submissions WHERE submission_type = 'savings_deposit';
  INSERT INTO earnings_ledger (member_id, kind, amount, occurred_at)
  VALUES (NULL, 'penalty', 5000, TIMESTAMPTZ '2025-06-01 10:00+03');

  SELECT COALESCE(SUM(earnings_tzs), 0) INTO v_total
    FROM preview_cycle_close(v_cycle, 'earnings_only');
  PERFORM tests.eq(v_total, 0, 'a zero total basis distributes nothing');

  -- ============================================== closing freezes the numbers
  PERFORM tests.give_savings(v_early, 100000, TIMESTAMPTZ '2025-01-05 10:00+03');
  DELETE FROM earnings_ledger;
  INSERT INTO earnings_ledger (member_id, kind, amount, occurred_at)
  VALUES (v_early, 'interest', 60000, TIMESTAMPTZ '2025-06-01 10:00+03');

  PERFORM tests.as_user(v_admin);
  v_closure := request_cycle_close(v_cycle, 'earnings_only', 'test: close the year');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM cycles WHERE id = v_cycle), 'closed', 'the cycle closed');
  PERFORM tests.eq(
    (SELECT total_payout_tzs FROM distributions WHERE cycle_id = v_cycle AND member_id = v_early),
    60000, 'the distribution is written');

  -- A later savings correction must NOT restate an agreed share-out.
  PERFORM tests.give_savings(v_late, 5000000, TIMESTAMPTZ '2025-02-01 10:00+03');
  PERFORM tests.eq(
    (SELECT total_payout_tzs FROM distributions WHERE cycle_id = v_cycle AND member_id = v_early),
    60000, 'the snapshot is immutable once the cycle is closed');

  -- The group keeps running: a new cycle opens where the old one ended.
  PERFORM tests.eq((SELECT count(*)::numeric FROM cycles WHERE status = 'open'), 1,
    'exactly one cycle is open again');
  PERFORM tests.eq((SELECT start_date::text FROM cycles WHERE status = 'open'),
    (v_end + 1)::text, 'the next cycle starts the day the last one ended');

  -- ============================================== full share-out needs settled loans
  SELECT id INTO v_cycle FROM cycles WHERE status = 'open';
  PERFORM tests.give_savings(v_early, 400000);
  INSERT INTO loans (member_id, principal, status)
  VALUES (v_early, 50000, 'pending') RETURNING id INTO v_loan;
  PERFORM tests.as_user(v_admin);
  PERFORM approve_loan(v_loan, 'test://disbursement');

  PERFORM tests.raises(
    format($q$ SELECT request_cycle_close(%L, 'full_shareout', 'test') $q$, v_cycle),
    'capital cannot be returned while a loan is still out');
  PERFORM tests.as_owner();
END;
$$;
