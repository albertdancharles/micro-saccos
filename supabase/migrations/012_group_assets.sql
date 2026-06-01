-- 012_group_assets.sql — total group assets view.
--
-- v_group_pool is liquid cash (loanable balance) — it already subtracts every
-- active/closed loan's principal. The "total group assets" answers the broader
-- question: what is the group worth in total? That is the liquid pool PLUS
-- everything still owed back by active borrowers (outstanding_principal).
--
-- Returned columns:
--   pool_balance_tzs      — same as v_group_pool.pool_balance_tzs (liquid cash)
--   outstanding_loans_tzs — sum of outstanding_principal for active loans
--   total_assets_tzs      — pool + outstanding loans (the group's net wealth)

CREATE OR REPLACE VIEW v_group_assets AS
SELECT
  (SELECT pool_balance_tzs FROM v_group_pool) AS pool_balance_tzs,
  COALESCE(
    (SELECT SUM(outstanding_principal) FROM loans WHERE status = 'active'),
    0
  ) AS outstanding_loans_tzs,
  (SELECT pool_balance_tzs FROM v_group_pool) +
    COALESCE(
      (SELECT SUM(outstanding_principal) FROM loans WHERE status = 'active'),
      0
    ) AS total_assets_tzs;

GRANT SELECT ON v_group_assets TO authenticated;
