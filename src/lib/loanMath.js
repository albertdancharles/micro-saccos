// Pure financial helpers, mirroring the SQL rules in the build plan so the UI can
// preview figures without a round-trip. Money rounds to whole TZS.

// Loan ceiling = 5x approved savings (Decision #4). Active-principal subtraction
// is unnecessary because a member may hold only one loan at a time.
export const loanCeiling = (approvedSavings) => Number(approvedSavings) * 5

// Pool ceiling: a single loan may not exceed 25% of the group pool, so one member
// can't drain it and others can still borrow. Floored to whole TZS so it never
// rounds above the cap.
export const POOL_LOAN_FRACTION = 0.25
export const poolCeiling = (poolBalance) => Math.floor(Number(poolBalance) * POOL_LOAN_FRACTION)

// Effective maximum loan = the lower of the 5x savings ceiling and the 25% pool
// ceiling. Both must hold.
export const maxLoan = (approvedSavings, poolBalance) =>
  Math.min(loanCeiling(approvedSavings), poolCeiling(poolBalance))

// Flat monthly interest = principal x 5%, whole shillings (Decision #2).
export const monthlyInterest = (principal) => Math.round(Number(principal) * 0.05)

// Live overdue penalty (Decision #6): simple, 5% x base x monthsOverdue, whole TZS.
// `monthsOverdue` is the multiplier the status views expose as penalty_months.
export const penaltyDue = (base, monthsOverdue) =>
  monthsOverdue > 0 ? Math.round(0.05 * Number(base) * Number(monthsOverdue)) : 0
