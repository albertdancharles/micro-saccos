-- 027_reconciliation.sql — prove the books balance, and make the views scope the
-- way the comments always claimed they did.
--
-- TWO UNRELATED FIXES, both about trusting what the app displays.
--
-- 1. RECONCILIATION. v_group_pool is now a ten-term expression over eight tables,
--    rewritten three times (021 cash correction, 022 write-offs and recoveries,
--    024 distributions). Nothing checks it against anything. A drift would surface
--    as a number that is quietly wrong — the worst kind of bug in a system whose
--    only product is numbers members trust.
--
--    So compute the group's worth a second way, from an independent direction, and
--    compare. Assets and claims must agree:
--
--      ASSETS  = liquid pool + principal still out on active loans
--      CLAIMS  = member capital + retained earnings − earnings already paid out
--
--    Where member capital is what members put in (deposits + fee base + approved
--    adjustments) and retained earnings is everything the group made (interest +
--    penalties − write-offs). The two are derived from different tables by
--    different paths, so agreement is meaningful; a non-zero difference means a
--    money path exists that one of them does not know about.
--
-- 2. security_invoker. 003_rls_policies.sql:50 says the status/money views scope
--    per member "(security_invoker default)". That is backwards: Postgres views
--    default to security_invoker = FALSE and run with the OWNER's rights, which
--    bypasses RLS on the tables underneath. On a project where the views are owned
--    by a privileged role, any member could read every other member's fee and
--    installment rows straight out of v_fee_status_money. This sets the flag the
--    comment always assumed, and 05_guards.test.sql asserts it from now on.

-- --------------------------------------------------------------------------
-- 1. security_invoker on the member-scoped views.
--
--    The policies underneath are already `own row OR is_admin()`, so admins keep
--    seeing everything and members see themselves. The SECURITY DEFINER RPCs
--    (approve_submission, approve_loan, the cycle functions) run as their owner
--    and are unaffected.
--
--    v_group_pool and v_group_assets are deliberately LEFT ALONE: they are single
--    aggregates over the whole group with no per-member rows to leak, every member
--    is entitled to see them, and they are read inside SECURITY DEFINER functions
--    that must not be subject to the caller's RLS.
-- --------------------------------------------------------------------------

ALTER VIEW v_fee_status                SET (security_invoker = true);
ALTER VIEW v_fee_status_money          SET (security_invoker = true);
ALTER VIEW v_installment_status        SET (security_invoker = true);
ALTER VIEW v_installment_status_money  SET (security_invoker = true);

-- --------------------------------------------------------------------------
-- 2. The identity, one component per row so a mismatch says WHERE it is.
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_pool_reconciliation AS
WITH
  -- What members have put in and not taken out. Withdrawals and returned capital
  -- both land here as negative savings_adjustments, so this needs no special case.
  capital AS (
    SELECT
        COALESCE((SELECT SUM(amount_claimed) FROM payment_submissions
                   WHERE submission_type = 'savings_deposit' AND status = 'approved'), 0)
      + COALESCE((SELECT SUM(amount_paid) FROM monthly_fees), 0)
      + COALESCE((SELECT SUM(delta) FROM savings_adjustments WHERE status = 'approved'), 0)
      AS member_capital
  ),
  -- What the group has earned over its whole life, less what it has paid out.
  earnings AS (
    SELECT
        COALESCE((SELECT SUM(amount) FROM earnings_ledger), 0)
      - COALESCE((SELECT SUM(earnings_tzs) FROM distributions WHERE status = 'paid'), 0)
      AS retained_earnings
  ),
  -- Admin corrections to the pool that are not attributable to any member. A
  -- legitimate part of the group's worth, so the identity has to include them or
  -- every pool edit would look like a discrepancy.
  adjustments AS (
    SELECT COALESCE((SELECT SUM(delta) FROM pool_adjustments WHERE status = 'approved'), 0)
      AS pool_adjustments_tzs
  ),
  assets AS (
    SELECT
      (SELECT pool_balance_tzs FROM v_group_pool) AS pool_tzs,
      COALESCE((SELECT SUM(outstanding_principal) FROM loans WHERE status = 'active'), 0)
        AS outstanding_tzs
  )
SELECT
  a.pool_tzs,
  a.outstanding_tzs,
  a.pool_tzs + a.outstanding_tzs                              AS total_assets_tzs,
  c.member_capital                                            AS member_capital_tzs,
  e.retained_earnings                                         AS retained_earnings_tzs,
  j.pool_adjustments_tzs,
  c.member_capital + e.retained_earnings + j.pool_adjustments_tzs AS total_claims_tzs,
  (a.pool_tzs + a.outstanding_tzs)
    - (c.member_capital + e.retained_earnings + j.pool_adjustments_tzs) AS difference_tzs,
  (a.pool_tzs + a.outstanding_tzs)
    = (c.member_capital + e.retained_earnings + j.pool_adjustments_tzs) AS balanced
FROM assets a, capital c, earnings e, adjustments j;

-- Every member can see that the group's books balance. That is the same
-- transparency stance as the member directory (019) and the share-out (024), and
-- a reconciliation only the admins can see is worth much less.
GRANT SELECT ON v_pool_reconciliation TO authenticated;
