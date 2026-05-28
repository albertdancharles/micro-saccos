// Pure financial helpers, mirroring the SQL rules in the build plan so the UI can
// preview figures without a round-trip. Money rounds to whole TZS.

// Loan ceilings (whole TZS, floored so we never round above the cap):
//   - 3× the member's contribution (approved savings + paid monthly fees) at the
//     time of request, so a borrower is anchored to what they've put in.
//   - 25% of the current group pool, so one member can't drain it.
// Effective max = the lower of the two; both must hold.
export const POOL_LOAN_FRACTION = 0.25
export const CONTRIBUTION_LOAN_MULTIPLIER = 3

export const poolCeiling = (poolBalance) =>
  Math.floor(Number(poolBalance) * POOL_LOAN_FRACTION)

export const contributionCeiling = (contribution) =>
  Math.floor(Number(contribution) * CONTRIBUTION_LOAN_MULTIPLIER)

export const maxLoan = (contribution, poolBalance) =>
  Math.min(contributionCeiling(contribution), poolCeiling(poolBalance))

// Flat monthly interest = principal x 5%, whole shillings (Decision #2).
export const monthlyInterest = (principal) => Math.round(Number(principal) * 0.05)

// Live overdue penalty (Decision #6): simple, 5% x base x monthsOverdue, whole TZS.
// `monthsOverdue` is the multiplier the status views expose as penalty_months.
export const penaltyDue = (base, monthsOverdue) =>
  monthsOverdue > 0 ? Math.round(0.05 * Number(base) * Number(monthsOverdue)) : 0
