-- 014_fee_overdue_and_savings.sql — overdue starts on the 1st of the next month.
--
-- Previously v_fee_status set due_date = period + 1 month (e.g. period 2026-05-01
-- → due_date 2026-06-01) and marked the fee 'overdue' only once today_eat() was
-- STRICTLY AFTER that day, so a May fee became overdue on 2026-06-02. The
-- intended semantic is that an unpaid fee turns overdue on the FIRST day of the
-- next month (2026-06-01 in the example).
--
-- Fix by anchoring due_date to the last day of the period's own month
-- (period + 1 month − 1 day = 2026-05-31), so "today > due_date" yields overdue
-- starting on 2026-06-01. The penalty multiplier likewise increments cleanly:
--   * 2026-06-01: age = 1 day  → penalty_months = 1
--   * 2026-07-01: age = 1 mo   → penalty_months = 2
--   * 2026-08-01: age = 2 mo   → penalty_months = 3
--
-- Column structure of the view is unchanged so CREATE OR REPLACE is safe and
-- v_fee_status_money (which depends on this view) keeps working as-is.
--
-- The "monthly fee paid → counts toward member's savings" change is a
-- frontend-only adjustment (lib/savings.js + the dashboard helpers); the SQL
-- views v_group_pool / v_group_assets already account for paid fees in the
-- group totals, so no SQL change is required for that part.

CREATE OR REPLACE VIEW v_fee_status AS
WITH b AS (
  SELECT mf.*,
         (mf.period + INTERVAL '1 month' - INTERVAL '1 day')::date AS due_date
  FROM monthly_fees mf
)
SELECT
  b.*,
  CASE
    WHEN b.status = 'paid' OR today_eat() <= b.due_date THEN 0
    ELSE (date_part('year',  age(today_eat(), b.due_date)) * 12
        + date_part('month', age(today_eat(), b.due_date)))::int + 1
  END AS penalty_months,
  CASE
    WHEN b.status = 'paid'        THEN 'paid'
    WHEN today_eat() > b.due_date THEN 'overdue'
    ELSE 'pending'
  END AS computed_status
FROM b;
