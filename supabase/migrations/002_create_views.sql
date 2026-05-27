-- 002_create_views.sql — overdue + penalty computed at query time (build plan §5).
-- Penalty rule (Decision #6): once past due, 5% × base applies and again each
-- completed month thereafter (simple, non-compounding). penalty_months is the
-- multiplier. All "today" comparisons use today_eat(); penalties round to whole TZS.

-- Monthly fees: due by the end of the period's month (period + 1 month).
CREATE OR REPLACE VIEW v_fee_status AS
WITH b AS (
  SELECT mf.*, (mf.period + INTERVAL '1 month')::date AS due_date
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

CREATE OR REPLACE VIEW v_fee_status_money AS
SELECT
  f.*,
  round(0.05 * f.amount * f.penalty_months)            AS penalty_due,
  f.amount + round(0.05 * f.amount * f.penalty_months) AS total_with_penalty
FROM v_fee_status f;

-- Loan installments: overdue if past due_date and not paid. Penalty base = total_due.
CREATE OR REPLACE VIEW v_installment_status AS
SELECT
  li.*,
  CASE
    WHEN li.status = 'paid' OR today_eat() <= li.due_date THEN 0
    ELSE (date_part('year',  age(today_eat(), li.due_date)) * 12
        + date_part('month', age(today_eat(), li.due_date)))::int + 1
  END AS penalty_months,
  CASE
    WHEN li.status = 'paid'        THEN 'paid'
    WHEN today_eat() > li.due_date THEN 'overdue'
    ELSE 'pending'
  END AS computed_status
FROM loan_installments li;

CREATE OR REPLACE VIEW v_installment_status_money AS
SELECT
  i.*,
  round(0.05 * i.total_due * i.penalty_months)               AS penalty_due,
  i.total_due + round(0.05 * i.total_due * i.penalty_months) AS total_with_penalty
FROM v_installment_status i;

-- Group pool balance (single aggregate; no member breakdown).
-- Cash in:  approved savings + paid fees (+ collected penalty) + paid installments (+ collected penalty)
-- Cash out: principal disbursed for active & closed loans
CREATE OR REPLACE VIEW v_group_pool AS
SELECT
    (SELECT COALESCE(SUM(amount_claimed), 0)
       FROM payment_submissions
       WHERE submission_type = 'savings_deposit' AND status = 'approved')
  + (SELECT COALESCE(SUM(amount), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM monthly_fees      WHERE status = 'paid')
  + (SELECT COALESCE(SUM(total_due), 0) + COALESCE(SUM(penalty_collected), 0)
       FROM loan_installments WHERE status = 'paid')
  - (SELECT COALESCE(SUM(principal), 0)
       FROM loans             WHERE status IN ('active', 'closed'))
  AS pool_balance_tzs;
