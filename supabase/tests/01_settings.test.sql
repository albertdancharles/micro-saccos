-- 01_settings.test.sql — group_settings and the rate-snapshot rule (migration 020).
--
-- The rule worth protecting: changing a rate must govern only NEW obligations. If
-- the money views ever read setting() live instead of the row's own snapshot, a
-- vote to lower the penalty would retroactively rewrite every penalty the group has
-- already charged — and nobody would notice until a member disputed their balance.

DO $$
DECLARE
  v_admin   uuid;
  v_member  uuid;
  v_old_fee uuid;
  v_new_fee uuid;
  v_penalty_before numeric;
  v_penalty_after  numeric;
  v_period  date := (date_trunc('month', today_eat()) - INTERVAL '3 months')::date;
BEGIN
  -- ---------------------------------------------------------------- accessor
  PERFORM tests.eq(setting('monthly_fee_amount'),      10000, 'seeded monthly fee');
  PERFORM tests.eq(setting('loan_interest_rate'),       0.05, 'seeded interest rate');
  PERFORM tests.eq(setting('penalty_rate'),             0.05, 'seeded penalty rate');
  PERFORM tests.eq(setting('pool_loan_fraction'),       0.25, 'seeded pool fraction');
  PERFORM tests.eq(setting('contribution_multiplier'),     3, 'seeded multiplier');

  -- An unknown key must not raise: setting() is called inside live RPCs and a
  -- missing row has to degrade to the old hardcoded behaviour, never a 500.
  PERFORM tests.eq(setting('no_such_setting'), 0, 'unknown key falls back');

  v_admin  := tests.make_admin('Settings Admin');
  v_member := tests.make_member('Settings Member');

  -- An overdue fee raised under the 5% rule.
  v_old_fee := tests.give_fee(v_member, v_period);
  PERFORM tests.eq(
    (SELECT penalty_rate FROM monthly_fees WHERE id = v_old_fee),
    0.05, 'fee snapshots the rate in force when it was raised');

  SELECT penalty_due INTO v_penalty_before
    FROM v_fee_status_money WHERE id = v_old_fee;

  -- The fixture only proves anything if the fee is actually accruing.
  IF v_penalty_before <= 0 THEN
    RAISE EXCEPTION 'fixture is wrong: the fee should be overdue and accruing';
  END IF;

  -- ------------------------------------------------------- change the rate
  -- With a single admin the 2-of-N threshold is 0 others, so this auto-applies —
  -- which also exercises the single-admin bootstrap path.
  PERFORM tests.as_user(v_admin);
  PERFORM request_setting_change('penalty_rate', 0.10, 'test: double the penalty');
  PERFORM tests.as_owner();

  PERFORM tests.eq(setting('penalty_rate'), 0.10, 'the vote applied');

  -- THE ASSERTION THIS FILE EXISTS FOR: the existing fee is untouched.
  SELECT penalty_due INTO v_penalty_after
    FROM v_fee_status_money WHERE id = v_old_fee;
  PERFORM tests.eq(v_penalty_after, v_penalty_before,
    'a rate change must NOT restate a penalty already charged');

  -- …while a fee raised afterwards uses the new rate.
  v_new_fee := tests.give_fee(v_member, (date_trunc('month', today_eat()))::date);
  PERFORM tests.eq(
    (SELECT penalty_rate FROM monthly_fees WHERE id = v_new_fee),
    0.10, 'a new fee picks up the new rate');

  -- ensure_current_fees() must raise fees at the CURRENT amount, not a literal.
  PERFORM tests.as_user(v_admin);
  PERFORM request_setting_change('monthly_fee_amount', 20000, 'test: raise the fee');
  PERFORM tests.as_owner();

  DELETE FROM monthly_fees WHERE period = date_trunc('month', today_eat())::date;
  PERFORM ensure_current_fees();
  PERFORM tests.eq(
    (SELECT DISTINCT amount FROM monthly_fees
      WHERE period = date_trunc('month', today_eat())::date),
    20000, 'ensure_current_fees uses the current setting');

  -- ------------------------------------------------------------- guard rails
  PERFORM tests.as_user(v_admin);
  -- 500% interest is a fat finger, not a policy: min/max must refuse it.
  PERFORM tests.raises(
    $q$ SELECT request_setting_change('loan_interest_rate', 5.0, 'oops') $q$,
    'a rate above max_value is refused');
  PERFORM tests.raises(
    $q$ SELECT request_setting_change('penalty_rate', 0.10, 'same value') $q$,
    'setting a value to what it already is, is refused');
  PERFORM tests.raises(
    $q$ SELECT request_setting_change('made_up_key', 1, 'nope') $q$,
    'an unknown setting key is refused');
  PERFORM tests.raises(
    $q$ SELECT request_setting_change('penalty_rate', 0.20, '') $q$,
    'a rule change without a reason is refused');
  PERFORM tests.as_owner();

  -- A non-admin can never change the group's rules.
  PERFORM tests.as_user(v_member);
  PERFORM tests.raises(
    $q$ SELECT request_setting_change('penalty_rate', 0.01, 'let me off') $q$,
    'a member cannot change the rules');
  PERFORM tests.as_owner();
END;
$$;
