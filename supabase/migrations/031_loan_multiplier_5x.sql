-- 031_loan_multiplier_5x.sql — the loan ceiling moves from 3x savings to 5x.
--
-- `contribution_multiplier` has been a group_settings row since 020, so this is a
-- value change, not a logic change: every RPC and view already reads setting().
-- It is done as a migration rather than a 2-of-N vote because it is the rule the
-- group agreed to run on, and a fresh project must stand up with 5x too — the seed
-- in 020 is `ON CONFLICT DO NOTHING`, so an existing database keeps 3 until this
-- UPDATE runs.
--
-- What actually changes, and what does not:
--   * The contribution ceiling on a NEW request rises to floor(5 x contribution).
--     The 25% pool cap is untouched, and the effective max is still the LOWER of
--     the two — for most members the pool side will now be what binds.
--   * Loans already approved are not restated. The cap gates request/approval
--     only; nothing recomputes an existing principal.
--   * The withdrawal collateral guard (025) locks `outstanding / multiplier`, so a
--     borrower's locked savings FALL. A 90,000 outstanding locked 30,000 at 3x and
--     locks 18,000 at 5x. That is the same rule, not a loosened one: it still
--     mirrors the ceiling a loan of that size was approved under.
--
-- Requires 020.

UPDATE group_settings
   SET value = 5, updated_at = now()
 WHERE key = 'contribution_multiplier';

-- The COALESCE fallback in setting() has to move with the row, otherwise a
-- database that somehow lost the row would silently revert to 3x.
CREATE OR REPLACE FUNCTION setting(p_key text)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT value FROM group_settings WHERE key = p_key),
    CASE p_key
      WHEN 'monthly_fee_amount'     THEN 10000
      WHEN 'loan_interest_rate'     THEN 0.05
      WHEN 'penalty_rate'           THEN 0.05
      WHEN 'pool_loan_fraction'     THEN 0.25
      WHEN 'contribution_multiplier' THEN 5
      WHEN 'default_loan_months'    THEN 3
      ELSE 0
    END
  );
$$;

GRANT EXECUTE ON FUNCTION setting(text) TO authenticated;
