-- 22_monthly_settlement.test.sql — one action settles the whole group's month (049).
--
-- What must hold, because this is one tap that moves every member's money:
--
--   * It takes INTEREST, never principal. The waterfall sends any surplus on an
--     installment to early principal without complaint, so an amount that is wrong
--     by even one row would quietly shorten somebody's loan. Asserted everywhere.
--   * The signature rules do not change. The overseer signs alone; for anyone else
--     interest and their own money still need a second admin. The batch removes the
--     per-member WORK, not the second pair of eyes.
--   * It is all-or-nothing, and what posts is exactly what the admin was shown.
--   * It does not send one notification per row. Each is a billable SMS (026).

-- A term that holds whatever month this runs in (051): these blocks need a loan
-- with interest-only rows before its final one.
SELECT tests.fix_loan_term(3);

-- A clean group for each block: the file runs in one transaction, so admins and
-- members from the block above would otherwise still be active and on the sheet.
CREATE FUNCTION pg_temp.fresh_group() RETURNS void AS $$
BEGIN
  PERFORM tests.as_owner();
  UPDATE profiles SET is_superadmin = false WHERE is_superadmin;
  UPDATE profiles SET is_active = false WHERE is_active;
END;
$$ LANGUAGE plpgsql;

-- A fee that has already fallen due. Last month's, so it is due whatever day the
-- suite runs on, and penalty-free unless a test asks for one.
CREATE FUNCTION pg_temp.due_fee(p_member uuid, p_penalty_rate numeric DEFAULT 0)
RETURNS uuid AS $$
DECLARE
  v_id uuid;
BEGIN
  v_id := tests.give_fee(
    p_member, (date_trunc('month', today_eat()) - interval '1 month')::date, 10000);
  UPDATE monthly_fees SET penalty_rate = p_penalty_rate WHERE id = v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- A real loan through the real path, signed by the given overseer, with its first
-- installment falling due today: the state on the morning of a meeting. The savings
-- are five times the principal so the loan clears the 25%-of-assets cap (045).
CREATE FUNCTION pg_temp.active_loan(p_overseer uuid, p_member uuid, p_principal numeric)
RETURNS uuid AS $$
DECLARE
  v_loan uuid;
BEGIN
  PERFORM tests.as_owner();
  PERFORM tests.give_savings(p_member, p_principal * 5);
  PERFORM tests.as_user(p_overseer);
  v_loan := file_loan(p_member, p_principal);
  PERFORM approve_loan(v_loan, NULL);
  PERFORM tests.as_owner();
  UPDATE loan_installments SET due_date = today_eat(), penalty_rate = 0
   WHERE loan_id = v_loan AND installment_number = 1;
  UPDATE loan_installments SET penalty_rate = 0
   WHERE loan_id = v_loan AND installment_number > 1;
  RETURN v_loan;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.first_installment(p_loan uuid) RETURNS uuid AS $$
  SELECT id FROM loan_installments WHERE loan_id = p_loan AND installment_number = 1;
$$ LANGUAGE sql;

-- Everything on the sheet, as the entries the client would send.
CREATE FUNCTION pg_temp.all_entries() RETURNS jsonb AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', s.kind, 'id', s.related_id)), '[]'::jsonb)
    FROM monthly_settlement_sheet() s;
$$ LANGUAGE sql;

CREATE FUNCTION pg_temp.sheet_total() RETURNS numeric AS $$
  SELECT COALESCE(SUM(s.amount), 0) FROM monthly_settlement_sheet() s;
$$ LANGUAGE sql;

-- ============================================================================
-- A. The overseer settles everybody with one call — own money included.
-- ============================================================================
DO $$
DECLARE
  v_boss    uuid;
  v_m1      uuid;
  v_m2      uuid;
  v_fee1    uuid;
  v_fee2    uuid;
  v_fee3    uuid;
  v_loan1   uuid;
  v_loan2   uuid;
  v_inst1   uuid;
  v_pool    numeric;
  v_result  jsonb;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_boss := tests.make_overseer('Settle Overseer');
  v_m1   := tests.make_member('Settle One');
  v_m2   := tests.make_member('Settle Two');

  v_loan1 := pg_temp.active_loan(v_boss, v_m1, 100000);    -- 5,000 interest
  v_loan2 := pg_temp.active_loan(v_boss, v_boss, 40000);   -- 2,000 interest, own loan
  v_inst1 := pg_temp.first_installment(v_loan1);

  v_fee1 := pg_temp.due_fee(v_m1);
  v_fee2 := pg_temp.due_fee(v_m2);
  v_fee3 := pg_temp.due_fee(v_boss);

  v_pool := tests.pool();

  PERFORM tests.as_user(v_boss);
  PERFORM tests.eq((SELECT count(*) FROM monthly_settlement_sheet())::numeric, 5,
    'three fees and two interest rows are due');
  PERFORM tests.eq(pg_temp.sheet_total(), 37000, '30,000 of fees + 7,000 of interest');
  PERFORM tests.eq(
    (SELECT count(*) FROM monthly_settlement_sheet() WHERE needs_second_signature)::numeric, 0,
    'the overseer needs nobody else, own money included');

  v_result := record_monthly_settlement(pg_temp.all_entries(), 37000);
  PERFORM tests.as_owner();

  PERFORM tests.eq((v_result->>'settled_count')::numeric, 5, 'all five post at once');
  PERFORM tests.eq((v_result->>'settled_total')::numeric, 37000, 'the whole total posts');
  PERFORM tests.eq((v_result->>'awaiting_count')::numeric, 0, 'nothing waits');

  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee1), 'paid', 'a member fee');
  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee3), 'paid', 'the overseer''s own fee');

  -- THE property: it is interest, and only interest.
  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_inst1), 5000,
    'the interest is paid');
  PERFORM tests.eq((SELECT principal_paid FROM loan_installments WHERE id = v_inst1), 0,
    'no principal is touched');
  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_loan1), 100000,
    'the loan balance is exactly what it was');
  PERFORM tests.eq((SELECT status FROM loan_installments WHERE id = v_inst1), 'paid',
    'an interest-only installment is finished once its interest is in');
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan1), 'active', 'the loan stays open');

  -- Same books as paying each member by hand.
  PERFORM tests.eq(tests.pool(), v_pool + 37000, 'the pool has every shilling');
  PERFORM tests.eq(
    (SELECT COALESCE(SUM(amount), 0) FROM earnings_ledger
      WHERE kind = 'interest' AND source_id = v_inst1),
    5000, 'interest is booked as group earnings');
  PERFORM tests.assert_balanced('settling the month');

  -- The rows are ordinary payments: on the member's history, tied to the batch.
  PERFORM tests.eq(
    (SELECT count(*) FROM payment_submissions
      WHERE settlement_batch_id = (v_result->>'batch_id')::uuid
        AND status = 'approved')::numeric,
    5, 'every row is a settled payment in the same batch');

  -- One message per member, not one per row and not one per admin per row.
  PERFORM tests.eq(
    (SELECT count(*) FROM notifications
      WHERE recipient_id = v_m1 AND kind = 'settlement_recorded')::numeric,
    1, 'a member with a fee AND interest hears once');
  PERFORM tests.eq(
    (SELECT count(*) FROM notifications
      WHERE kind IN ('new_submission', 'submission_approved')
        AND (data ->> 'submission_id')::uuid IN (
          SELECT id FROM payment_submissions
           WHERE settlement_batch_id = (v_result->>'batch_id')::uuid))::numeric,
    0, 'no per-row notifications');
  PERFORM tests.eq(
    (SELECT (data ->> 'amount')::numeric FROM notifications
      WHERE recipient_id = v_m1 AND kind = 'settlement_recorded'),
    15000, 'the message carries that member''s total');

  -- Nothing left, and pressing it again cannot pay anyone twice.
  PERFORM tests.as_user(v_boss);
  PERFORM tests.eq((SELECT count(*) FROM monthly_settlement_sheet())::numeric, 0,
    'the sheet is empty afterwards');
  PERFORM tests.raises(format($q$
    SELECT record_monthly_settlement(
      jsonb_build_array(jsonb_build_object('kind', 'interest', 'id', %L)), 5000) $q$, v_inst1),
    'a row already settled is refused');
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_inst1), 5000,
    'and nothing moved');

  RAISE NOTICE '22A ok';
END;
$$;

-- ============================================================================
-- B. What is on the sheet: due, active, outstanding — nothing else.
-- ============================================================================
DO $$
DECLARE
  v_boss   uuid;
  v_m      uuid;
  v_gone   uuid;
  v_loan   uuid;
  v_future uuid;
  v_next   uuid;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_boss := tests.make_overseer('Sheet Overseer');
  v_m    := tests.make_member('Sheet Member');
  v_gone := tests.make_member('Sheet Former');

  v_loan := pg_temp.active_loan(v_boss, v_m, 100000);

  -- Next month's fee has not fallen due. Nor has the second installment.
  v_future := tests.give_fee(
    v_m, (date_trunc('month', today_eat()) + interval '1 month')::date, 10000);
  SELECT id INTO v_next FROM loan_installments
   WHERE loan_id = v_loan AND installment_number = 2;

  -- A former member's row is not this meeting's business.
  PERFORM pg_temp.due_fee(v_gone);
  UPDATE profiles SET is_active = false WHERE id = v_gone;

  PERFORM tests.as_user(v_boss);
  PERFORM tests.eq((SELECT count(*) FROM monthly_settlement_sheet())::numeric, 1,
    'only the installment due today');
  PERFORM tests.eq((SELECT kind FROM monthly_settlement_sheet()), 'interest', 'and it is interest');

  PERFORM tests.raises(format($q$
    SELECT record_monthly_settlement(
      jsonb_build_array(jsonb_build_object('kind', 'fee', 'id', %L)), 10000) $q$, v_future),
    'a fee not yet due cannot be slipped in');
  PERFORM tests.raises(format($q$
    SELECT record_monthly_settlement(
      jsonb_build_array(jsonb_build_object('kind', 'interest', 'id', %L)), 5000) $q$, v_next),
    'interest not yet due cannot be slipped in');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_next), 0,
    'nothing moved');

  RAISE NOTICE '22B ok';
END;
$$;

-- ============================================================================
-- C. The final installment: interest settles, the principal stays owed.
--
--    December's row carries the whole principal as well as the interest. Settling
--    "the month's interest" must not touch it — the row is left part-paid and the
--    member still owes the principal, visibly. All three installments fall due at
--    once here, which is also the arrears case: several rows on one loan.
-- ============================================================================
DO $$
DECLARE
  v_boss uuid;
  v_m    uuid;
  v_loan uuid;
  v_last uuid;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_boss := tests.make_overseer('Final Overseer');
  v_m    := tests.make_member('Final Member');
  v_loan := pg_temp.active_loan(v_boss, v_m, 100000);

  UPDATE loan_installments SET due_date = today_eat() WHERE loan_id = v_loan;
  SELECT id INTO v_last FROM loan_installments
   WHERE loan_id = v_loan AND principal_due > 0;

  PERFORM tests.as_user(v_boss);
  PERFORM tests.eq(pg_temp.sheet_total(), 15000, 'three months of interest, not 115,000');
  PERFORM record_monthly_settlement(pg_temp.all_entries(), 15000);
  PERFORM tests.as_owner();

  PERFORM tests.eq(
    (SELECT SUM(principal_paid) FROM loan_installments WHERE loan_id = v_loan), 0,
    'the principal is untouched');
  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_loan), 100000,
    'the whole balance is still out');
  PERFORM tests.eq((SELECT status FROM loan_installments WHERE id = v_last), 'partial',
    'the last row stays open for the principal');
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan), 'active', 'the loan is not closed');
  PERFORM tests.eq(
    (SELECT remaining FROM v_installment_status_money WHERE id = v_last), 100000,
    'the member still visibly owes the principal');
  PERFORM tests.assert_balanced('interest on a final installment');

  RAISE NOTICE '22C ok';
END;
$$;

-- ============================================================================
-- D. A penalty is settled with the row, because the waterfall takes it first.
--    Offering only the base would leave the row short and the admin confused.
-- ============================================================================
DO $$
DECLARE
  v_boss uuid;
  v_m    uuid;
  v_fee  uuid;
  v_pen  numeric;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_boss := tests.make_overseer('Penalty Overseer');
  v_m    := tests.make_member('Penalty Member');
  v_fee  := pg_temp.due_fee(v_m, 0.05);

  SELECT penalty_due INTO v_pen FROM v_fee_status_money WHERE id = v_fee;
  PERFORM tests.eq((v_pen > 0)::text, 'true', 'a late fee at 5% carries a penalty');

  PERFORM tests.as_user(v_boss);
  PERFORM tests.eq((SELECT amount FROM monthly_settlement_sheet()), 10000 + v_pen, 'base + penalty');
  PERFORM tests.eq((SELECT penalty FROM monthly_settlement_sheet()), v_pen, 'shown separately');
  PERFORM record_monthly_settlement(pg_temp.all_entries(), 10000 + v_pen);
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee), 'paid', 'settled in full');
  PERFORM tests.eq((SELECT penalty_collected FROM monthly_fees WHERE id = v_fee), v_pen,
    'the penalty was banked');
  PERFORM tests.assert_balanced('a penalty inside a settlement');

  RAISE NOTICE '22D ok';
END;
$$;

-- ============================================================================
-- E. All-or-nothing, and exactly what was shown.
-- ============================================================================
DO $$
DECLARE
  v_boss uuid;
  v_m1   uuid;
  v_m2   uuid;
  v_fee1 uuid;
  v_fee2 uuid;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_boss := tests.make_overseer('Atomic Overseer');
  v_m1   := tests.make_member('Atomic One');
  v_m2   := tests.make_member('Atomic Two');
  v_fee1 := pg_temp.due_fee(v_m1);
  v_fee2 := pg_temp.due_fee(v_m2);

  PERFORM tests.as_user(v_boss);

  -- The total the admin saw disagrees with the server: nothing posts.
  PERFORM tests.raises(format($q$
    SELECT record_monthly_settlement(pg_temp.all_entries(), 19999) $q$),
    'a total that differs from what was shown is refused');

  -- One bad row sinks the batch, including the good row before it.
  PERFORM tests.raises(format($q$
    SELECT record_monthly_settlement(jsonb_build_array(
      jsonb_build_object('kind', 'fee', 'id', %L),
      jsonb_build_object('kind', 'fee', 'id', gen_random_uuid())), 10000) $q$, v_fee1),
    'an unknown row rejects the whole batch');

  PERFORM tests.raises(format($q$
    SELECT record_monthly_settlement(jsonb_build_array(
      jsonb_build_object('kind', 'fee', 'id', %L),
      jsonb_build_object('kind', 'fee', 'id', %L)), 20000) $q$, v_fee1, v_fee1),
    'the same row twice is refused');

  PERFORM tests.raises($q$ SELECT record_monthly_settlement('[]'::jsonb, 0) $q$,
    'an empty sheet is refused');
  PERFORM tests.raises($q$
    SELECT record_monthly_settlement(
      jsonb_build_array(jsonb_build_object('kind', 'savings', 'id', gen_random_uuid())), 0) $q$,
    'an unknown kind is refused');

  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee1), 'pending', 'nothing posted');
  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee2), 'pending', 'nothing posted');
  PERFORM tests.eq(
    (SELECT count(*) FROM payment_submissions WHERE related_id IN (v_fee1, v_fee2))::numeric,
    0, 'and no submission rows were left behind');

  -- Part of the sheet is a normal thing to post: anyone not ticked stays owing.
  PERFORM tests.as_user(v_boss);
  PERFORM record_monthly_settlement(
    jsonb_build_array(jsonb_build_object('kind', 'fee', 'id', v_fee1)), 10000);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee1), 'paid', 'ticked: settled');
  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee2), 'pending', 'unticked: still owes');

  RAISE NOTICE '22E ok';
END;
$$;

-- ============================================================================
-- F. Nobody but an admin gets near it, and the moving parts stay private.
-- ============================================================================
DO $$
DECLARE
  v_boss  uuid;
  v_m     uuid;
  v_fee   uuid;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_boss := tests.make_overseer('Gate Overseer');
  v_m    := tests.make_member('Gate Member');
  v_fee  := pg_temp.due_fee(v_m);

  PERFORM tests.as_user(v_m);
  PERFORM tests.raises($q$ SELECT * FROM monthly_settlement_sheet() $q$,
    'a member cannot read the sheet');
  PERFORM tests.raises(format($q$
    SELECT record_monthly_settlement(
      jsonb_build_array(jsonb_build_object('kind', 'fee', 'id', %L)), 10000) $q$, v_fee),
    'a member cannot settle their own fee');
  PERFORM tests.raises(format($q$ SELECT approve_monthly_settlement(%L) $q$, gen_random_uuid()),
    'a member cannot sign a batch');
  PERFORM tests.raises(format($q$ SELECT reject_monthly_settlement(%L, 'x') $q$, gen_random_uuid()),
    'a member cannot reject a batch');
  PERFORM tests.raises($q$ SELECT * FROM settlement_due_rows() $q$,
    'the private due-rows helper is not reachable');
  PERFORM tests.raises($q$ SELECT guard_settlement_row() $q$,
    'the guard is not reachable');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee), 'pending', 'nothing moved');

  -- anon must not even be able to call these. They gate on is_admin() anyway, but
  -- Supabase's default privileges grant to anon, so it has to be revoked by name.
  PERFORM tests.eq(
    (SELECT count(*) FROM pg_proc p
      WHERE p.proname IN ('monthly_settlement_sheet', 'record_monthly_settlement',
                          'approve_monthly_settlement', 'reject_monthly_settlement',
                          'settlement_due_rows', 'notify_settlement_members',
                          'guard_settlement_row')
        AND has_function_privilege('anon', p.oid, 'EXECUTE'))::numeric,
    0, 'anon can execute none of them');
  PERFORM tests.eq(
    (SELECT count(*) FROM pg_proc p
      WHERE p.proname IN ('settlement_due_rows', 'notify_settlement_members',
                          'guard_settlement_row')
        AND has_function_privilege('authenticated', p.oid, 'EXECUTE'))::numeric,
    0, 'the private helpers are not on the API');

  RAISE NOTICE '22F ok';
END;
$$;

-- ============================================================================
-- G. Two ordinary admins: fees post now, interest waits as ONE batch, and the
--    second admin signs it once — not thirteen times.
-- ============================================================================
DO $$
DECLARE
  v_a1      uuid;
  v_a2      uuid;
  v_boss    uuid;
  v_m1      uuid;
  v_m2      uuid;
  v_loan1   uuid;
  v_loan2   uuid;
  v_inst1   uuid;
  v_inst2   uuid;
  v_fee1    uuid;
  v_fee_own uuid;
  v_result  jsonb;
  v_signed  jsonb;
  v_batch   uuid;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_boss := tests.make_overseer('Temp Overseer');
  v_a1   := tests.make_admin('Batch Admin One');
  v_a2   := tests.make_admin('Batch Admin Two');
  v_m1   := tests.make_member('Batch One');
  v_m2   := tests.make_member('Batch Two');

  v_loan1 := pg_temp.active_loan(v_boss, v_m1, 100000);
  v_loan2 := pg_temp.active_loan(v_boss, v_m2, 60000);
  v_inst1 := pg_temp.first_installment(v_loan1);
  v_inst2 := pg_temp.first_installment(v_loan2);

  v_fee1    := pg_temp.due_fee(v_m1);
  v_fee_own := pg_temp.due_fee(v_a1);

  -- The overseer was only here to disburse. From now on, two ordinary admins.
  UPDATE profiles SET is_superadmin = false WHERE id = v_boss;
  UPDATE profiles SET is_active = false WHERE id = v_boss;

  PERFORM tests.as_user(v_a1);

  -- The sheet warns before the tap, and the warning matches what then happens.
  PERFORM tests.eq(
    (SELECT count(*) FROM monthly_settlement_sheet() WHERE needs_second_signature)::numeric,
    3, 'two interest rows and the admin''s own fee');
  PERFORM tests.eq(
    (SELECT needs_second_signature::text FROM monthly_settlement_sheet() WHERE related_id = v_fee1),
    'false', 'another member''s fee needs one');

  v_result := record_monthly_settlement(pg_temp.all_entries(), pg_temp.sheet_total());
  PERFORM tests.as_owner();
  v_batch := (v_result->>'batch_id')::uuid;

  PERFORM tests.eq((v_result->>'settled_count')::numeric, 1, 'the member''s fee posts');
  PERFORM tests.eq((v_result->>'settled_total')::numeric, 10000, '10,000 of it');
  PERFORM tests.eq((v_result->>'awaiting_count')::numeric, 3, 'three wait');
  PERFORM tests.eq((v_result->>'awaiting_total')::numeric, 18000,
    '5,000 + 3,000 of interest + the admin''s own 10,000');

  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee1), 'paid', 'fee posted');
  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee_own), 'pending',
    'the admin''s own fee has not');
  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_inst1), 0,
    'no interest has moved on one signature');
  PERFORM tests.assert_balanced('half a settlement');

  -- One message to the other admin. Not one per row, and not to the recorder.
  PERFORM tests.eq(
    (SELECT count(*) FROM notifications
      WHERE kind = 'settlement_awaiting_signature' AND recipient_id = v_a2)::numeric,
    1, 'the other admin is asked once');
  PERFORM tests.eq(
    (SELECT count(*) FROM notifications
      WHERE kind = 'settlement_awaiting_signature' AND recipient_id = v_a1)::numeric,
    0, 'and the recorder is not asked at all');

  -- Rows in flight leave the sheet, or a second admin could pay them again.
  PERFORM tests.as_user(v_a2);
  PERFORM tests.eq((SELECT count(*) FROM monthly_settlement_sheet())::numeric, 0,
    'waiting rows are not offered again');
  PERFORM tests.raises(format($q$
    SELECT record_monthly_settlement(
      jsonb_build_array(jsonb_build_object('kind', 'interest', 'id', %L)), 5000) $q$, v_inst1),
    'a row already waiting cannot be settled a second time');
  PERFORM tests.as_owner();

  -- The recorder cannot be their own second signature.
  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$ SELECT approve_monthly_settlement(%L) $q$, v_batch),
    'the recording admin cannot sign their own batch');
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_inst1), 0,
    'still nothing moved');

  -- One signature from the second admin finishes all of it.
  PERFORM tests.as_user(v_a2);
  v_signed := approve_monthly_settlement(v_batch);
  PERFORM tests.as_owner();

  PERFORM tests.eq((v_signed->>'signed_count')::numeric, 3, 'all three signed in one call');
  PERFORM tests.eq((v_signed->>'signed_total')::numeric, 18000, 'for the whole amount');
  PERFORM tests.eq((v_signed->>'left_count')::numeric, 0, 'none left');

  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee_own), 'paid',
    'the admin''s own fee, on two signatures');
  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_inst1), 5000, 'interest in');
  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_inst2), 3000, 'interest in');
  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_loan1), 100000, 'principal untouched');
  PERFORM tests.eq(
    (SELECT count(DISTINCT admin_id) FROM submission_approvals
      WHERE submission_id = (SELECT id FROM payment_submissions WHERE related_id = v_inst1))::numeric,
    2, 'two different signatures are on the row');
  PERFORM tests.assert_balanced('a settlement on two signatures');

  -- m1 got the fee first and the interest later: two moments, two short messages.
  PERFORM tests.eq(
    (SELECT count(*) FROM notifications
      WHERE recipient_id = v_m1 AND kind = 'settlement_recorded')::numeric,
    2, 'one message at each moment money posted for this member');
  PERFORM tests.eq(
    (SELECT count(*) FROM notifications
      WHERE recipient_id = v_m2 AND kind = 'settlement_recorded')::numeric,
    1, 'one for a member with interest alone');

  RAISE NOTICE '22G ok';
END;
$$;

-- ============================================================================
-- H. The overseer can be the second signature, on their own money too — and a
--    batch that went stale refuses rather than letting money land on principal.
-- ============================================================================
DO $$
DECLARE
  v_boss    uuid;
  v_kelvin  uuid;
  v_m       uuid;
  v_loan    uuid;
  v_own     uuid;
  v_inst    uuid;
  v_inst_o  uuid;
  v_batch   uuid;
  v_signed  jsonb;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_boss   := tests.make_overseer('Stale Overseer');
  v_kelvin := tests.make_admin('Stale Admin');
  v_m      := tests.make_member('Stale Member');
  v_loan   := pg_temp.active_loan(v_boss, v_m, 100000);
  v_own    := pg_temp.active_loan(v_boss, v_boss, 40000);
  v_inst   := pg_temp.first_installment(v_loan);
  v_inst_o := pg_temp.first_installment(v_own);

  PERFORM tests.as_user(v_kelvin);
  v_batch := (record_monthly_settlement(pg_temp.all_entries(), 7000) ->> 'batch_id')::uuid;
  PERFORM tests.as_owner();

  -- Something else paid this interest while the batch sat waiting.
  UPDATE loan_installments SET interest_paid = interest_due WHERE id = v_inst;

  PERFORM tests.as_user(v_boss);
  PERFORM tests.raises(format($q$ SELECT approve_monthly_settlement(%L) $q$, v_batch),
    'a figure that moved since recording is refused');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT principal_paid FROM loan_installments WHERE id = v_inst), 0,
    'the 5,000 did NOT fall through to principal');
  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_loan), 100000,
    'the balance did not move');
  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_inst_o), 0,
    'and the other row in the batch did not post either');

  -- The way out: reject the batch in one go, and the rows are back on the sheet.
  UPDATE loan_installments SET interest_paid = 0 WHERE id = v_inst;
  PERFORM tests.as_user(v_kelvin);
  PERFORM tests.raises(format($q$ SELECT reject_monthly_settlement(%L, '   ') $q$, v_batch),
    'a rejection needs a reason');
  PERFORM tests.eq(reject_monthly_settlement(v_batch, 'Pressed before the money came in')::numeric, 2,
    'both rows rejected at once');
  PERFORM tests.eq((SELECT count(*) FROM monthly_settlement_sheet())::numeric, 2, 'back on the sheet');
  PERFORM tests.as_owner();
  PERFORM tests.eq(
    (SELECT count(*) FROM notifications WHERE kind = 'submission_rejected')::numeric,
    0, 'members hear nothing about a payment they were never told was pending');
  PERFORM tests.assert_balanced('a rejected settlement');

  -- Run it again, and the overseer signs — their own interest included.
  PERFORM tests.as_user(v_kelvin);
  v_batch := (record_monthly_settlement(pg_temp.all_entries(), 7000) ->> 'batch_id')::uuid;
  PERFORM tests.as_owner();
  PERFORM tests.as_user(v_boss);
  v_signed := approve_monthly_settlement(v_batch);
  PERFORM tests.as_owner();

  PERFORM tests.eq((v_signed->>'signed_count')::numeric, 2, 'the overseer signs both');
  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_inst_o), 2000,
    'their own interest included');
  PERFORM tests.assert_balanced('the overseer as second signature');

  RAISE NOTICE '22H ok';
END;
$$;

-- ============================================================================
-- I. A signer's own money stays for someone else. Everything else still signs.
-- ============================================================================
DO $$
DECLARE
  v_boss uuid;
  v_a1   uuid;
  v_a2   uuid;
  v_a3   uuid;
  v_m    uuid;
  v_i_m  uuid;
  v_i_a2 uuid;
  v_batch uuid;
  v_signed jsonb;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_boss := tests.make_overseer('Three Overseer');
  v_a1   := tests.make_admin('Three Admin One');
  v_a2   := tests.make_admin('Three Admin Two');
  v_a3   := tests.make_admin('Three Admin Three');
  v_m    := tests.make_member('Three Member');
  v_i_m  := pg_temp.first_installment(pg_temp.active_loan(v_boss, v_m, 100000));
  v_i_a2 := pg_temp.first_installment(pg_temp.active_loan(v_boss, v_a2, 40000));
  UPDATE profiles SET is_superadmin = false WHERE id = v_boss;
  UPDATE profiles SET is_active = false WHERE id = v_boss;

  PERFORM tests.as_user(v_a1);
  v_batch := (record_monthly_settlement(pg_temp.all_entries(), 7000) ->> 'batch_id')::uuid;
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_a2);
  v_signed := approve_monthly_settlement(v_batch);
  PERFORM tests.as_owner();
  PERFORM tests.eq((v_signed->>'signed_count')::numeric, 1, 'the member''s row is signed');
  PERFORM tests.eq((v_signed->>'left_count')::numeric, 1, 'their own is left, and they are told');
  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_i_m), 5000, 'in');
  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_i_a2), 0, 'not yet');

  PERFORM tests.as_user(v_a2);
  PERFORM tests.raises(format($q$ SELECT approve_monthly_settlement(%L) $q$, v_batch),
    'with only their own row left, there is nothing for them to sign');
  PERFORM tests.as_owner();

  PERFORM tests.as_user(v_a3);
  v_signed := approve_monthly_settlement(v_batch);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_i_a2), 2000,
    'a third admin finishes it');
  PERFORM tests.assert_balanced('a batch signed in two sittings');

  RAISE NOTICE '22I ok';
END;
$$;

-- ============================================================================
-- J. A row nobody could ever sign is refused now, not left pending forever.
-- ============================================================================
DO $$
DECLARE
  v_a1  uuid;
  v_a2  uuid;
  v_m   uuid;
  v_own uuid;
  v_oth uuid;
  v_fee uuid;
BEGIN
  -- A lone ordinary admin and their own fee: 036's rule, no second signature exists.
  PERFORM pg_temp.fresh_group();
  v_a1  := tests.make_admin('Lone Admin');
  v_m   := tests.make_member('Lone Member');
  v_own := pg_temp.due_fee(v_a1);
  v_fee := pg_temp.due_fee(v_m);

  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$
    SELECT record_monthly_settlement(
      jsonb_build_array(jsonb_build_object('kind', 'fee', 'id', %L)), 10000) $q$, v_own),
    'a lone admin cannot settle their own fee');
  -- Without it, the rest of the sheet still goes through.
  PERFORM record_monthly_settlement(
    jsonb_build_array(jsonb_build_object('kind', 'fee', 'id', v_fee)), 10000);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee), 'paid', 'the member''s fee posts');
  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_own), 'pending', 'their own does not');

  -- Two ordinary admins, and A settling B's interest: B cannot sign their own and
  -- A has already signed, so that row could never finish. Refused up front.
  PERFORM pg_temp.fresh_group();
  v_a1 := tests.make_overseer('Pair Overseer');
  v_a2 := tests.make_admin('Pair Admin Two');
  v_oth := pg_temp.first_installment(pg_temp.active_loan(v_a1, v_a2, 40000));
  UPDATE profiles SET is_superadmin = false WHERE id = v_a1;

  PERFORM tests.as_user(v_a1);
  PERFORM tests.raises(format($q$
    SELECT record_monthly_settlement(
      jsonb_build_array(jsonb_build_object('kind', 'interest', 'id', %L)), 2000) $q$, v_oth),
    'a row with no possible second signer is refused');
  PERFORM tests.as_owner();
  PERFORM tests.eq(
    (SELECT count(*) FROM payment_submissions WHERE related_id = v_oth)::numeric, 0,
    'and it is not left pending');

  RAISE NOTICE '22J ok';
END;
$$;

-- ============================================================================
-- K. A mistake is correctable: one wrongly-settled member comes back out through
--    the ordinary void, on their own, and is owed again.
-- ============================================================================
DO $$
DECLARE
  v_boss uuid;
  v_m1   uuid;
  v_m2   uuid;
  v_loan uuid;
  v_inst uuid;
  v_fee  uuid;
  v_sub  uuid;
  v_pool numeric;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_boss := tests.make_overseer('Void Overseer');
  v_m1   := tests.make_member('Void One');
  v_m2   := tests.make_member('Void Two');
  v_loan := pg_temp.active_loan(v_boss, v_m1, 100000);
  v_inst := pg_temp.first_installment(v_loan);
  v_fee  := pg_temp.due_fee(v_m2);

  v_pool := tests.pool();
  PERFORM tests.as_user(v_boss);
  PERFORM record_monthly_settlement(pg_temp.all_entries(), 15000);
  PERFORM tests.as_owner();

  SELECT id INTO v_sub FROM payment_submissions WHERE related_id = v_inst;
  PERFORM tests.as_user(v_boss);
  PERFORM request_payment_void(v_sub, 'They had not actually paid');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_inst), 0,
    'the interest is unwound');
  PERFORM tests.eq((SELECT status FROM monthly_fees WHERE id = v_fee), 'paid',
    'and the rest of the batch stands');
  PERFORM tests.eq(tests.pool(), v_pool + 10000, 'the pool gave back that one row');
  PERFORM tests.assert_balanced('voiding a row of a settlement');

  PERFORM tests.as_user(v_boss);
  PERFORM tests.eq((SELECT related_id::text FROM monthly_settlement_sheet()), v_inst::text,
    'they are owed again, on the sheet');
  PERFORM tests.as_owner();

  RAISE NOTICE '22K ok';
END;
$$;

-- ============================================================================
-- L. Paying one member by hand still notifies as it always has. Only batch rows
--    went quiet.
-- ============================================================================
DO $$
DECLARE
  v_boss uuid;
  v_m    uuid;
  v_fee  uuid;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_boss := tests.make_overseer('Solo Overseer');
  v_m    := tests.make_member('Solo Member');
  v_fee  := pg_temp.due_fee(v_m);

  PERFORM tests.as_user(v_boss);
  PERFORM record_payment(v_m, 'monthly_fee', v_fee, 10000, NULL);
  PERFORM tests.as_owner();

  PERFORM tests.eq(
    (SELECT count(*) FROM notifications
      WHERE recipient_id = v_m AND kind = 'submission_approved')::numeric,
    1, 'the single-payment path still tells the member');

  RAISE NOTICE '22L ok';
END;
$$;

-- ============================================================================
-- M. A batch row posts only at what its row still owes, whichever path signs it.
--
--    approve_submission reaches settle_submission without going near
--    approve_monthly_settlement, so a check that lives only there leaves a door open:
--    a stale figure signed through the row's own Approve would land on principal.
-- ============================================================================
DO $$
DECLARE
  v_boss    uuid;
  v_kelvin  uuid;
  v_m1      uuid;
  v_m2      uuid;
  v_m3      uuid;
  v_loan1   uuid;
  v_loan2   uuid;
  v_loan3   uuid;
  v_i1      uuid;
  v_i1_next uuid;
  v_i3      uuid;
  v_sub1    uuid;
  v_sub2    uuid;
  v_sub3    uuid;
BEGIN
  PERFORM pg_temp.fresh_group();
  v_boss   := tests.make_overseer('Door Overseer');
  v_kelvin := tests.make_admin('Door Admin');
  v_m1     := tests.make_member('Door One');
  v_m2     := tests.make_member('Door Two');
  v_m3     := tests.make_member('Door Three');
  v_loan1  := pg_temp.active_loan(v_boss, v_m1, 100000);
  v_loan2  := pg_temp.active_loan(v_boss, v_m2, 100000);
  v_loan3  := pg_temp.active_loan(v_boss, v_m3, 100000);
  v_i1     := pg_temp.first_installment(v_loan1);
  v_i3     := pg_temp.first_installment(v_loan3);
  SELECT id INTO v_i1_next FROM loan_installments
   WHERE loan_id = v_loan1 AND installment_number = 2;

  PERFORM tests.as_user(v_kelvin);
  PERFORM record_monthly_settlement(pg_temp.all_entries(), 15000);
  PERFORM tests.as_owner();
  SELECT id INTO v_sub1 FROM payment_submissions WHERE related_id = v_i1;
  SELECT id INTO v_sub2 FROM payment_submissions
   WHERE related_id = pg_temp.first_installment(v_loan2);
  SELECT id INTO v_sub3 FROM payment_submissions WHERE related_id = v_i3;

  -- Early principal on a LATER installment re-prices this one down to 4,250, and the
  -- pending-row guard (011) does not stop it: it is a different installment.
  PERFORM tests.as_user(v_boss);
  PERFORM record_payment(v_m1, 'loan_installment', v_i1_next, 20000, NULL);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT interest_due FROM loan_installments WHERE id = v_i1), 4250,
    'the waiting row was re-priced underneath the batch');
  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_loan1), 85000,
    'after 5,000 of interest and 15,000 of principal');

  PERFORM tests.as_user(v_boss);
  PERFORM tests.raises(format($q$ SELECT approve_submission(%L, 5000) $q$, v_sub1),
    'the row''s own approve refuses a figure that has gone stale');
  PERFORM tests.as_owner();

  PERFORM tests.eq((SELECT principal_paid FROM loan_installments WHERE id = v_i1), 0,
    'the surplus 750 did NOT land on principal');
  PERFORM tests.eq((SELECT outstanding_principal FROM loans WHERE id = v_loan1), 85000,
    'the balance did not move');
  PERFORM tests.eq((SELECT status FROM payment_submissions WHERE id = v_sub1), 'pending',
    'the row is still waiting');

  -- A loan written off while the batch waits: its installments are gone, and paying
  -- one must neither revive it nor overwrite the write-off.
  PERFORM tests.as_user(v_boss);
  PERFORM request_loan_action(v_loan2, 'write_off', 'Left the district');
  PERFORM tests.raises(format($q$ SELECT approve_submission(%L, 5000) $q$, v_sub2),
    'a row on a written-off loan cannot be approved');
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT status FROM loans WHERE id = v_loan2), 'written_off',
    'the write-off stands');

  -- The guard must not get in the way of an honest row.
  PERFORM tests.as_user(v_boss);
  PERFORM approve_submission(v_sub3, 5000);
  PERFORM tests.as_owner();
  PERFORM tests.eq((SELECT interest_paid FROM loan_installments WHERE id = v_i3), 5000,
    'an unchanged figure still posts');
  PERFORM tests.eq((SELECT principal_paid FROM loan_installments WHERE id = v_i3), 0,
    'and only on interest');
  PERFORM tests.assert_balanced('a batch that went stale around its rows');

  RAISE NOTICE '22M ok';
END;
$$;
