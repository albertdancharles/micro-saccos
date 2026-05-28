// Pure financial helpers, mirroring the SQL rules in the build plan so the UI can
// preview figures without a round-trip. Money rounds to whole TZS.

// Maximum loan = 25% of the current group pool (whole TZS, floored so we never
// round above the cap). This is the sole ceiling — one member can't drain the
// pool, so others can still borrow. (Supersedes the original 5x-savings rule.)
export const POOL_LOAN_FRACTION = 0.25
export const poolCeiling = (poolBalance) =>
  Math.floor(Number(poolBalance) * POOL_LOAN_FRACTION)
export const maxLoan = (poolBalance) => poolCeiling(poolBalance)

// Flat monthly interest = principal x 5%, whole shillings (Decision #2).
export const monthlyInterest = (principal) => Math.round(Number(principal) * 0.05)

// Live overdue penalty (Decision #6): simple, 5% x base x monthsOverdue, whole TZS.
// `monthsOverdue` is the multiplier the status views expose as penalty_months.
export const penaltyDue = (base, monthsOverdue) =>
  monthsOverdue > 0 ? Math.round(0.05 * Number(base) * Number(monthsOverdue)) : 0
