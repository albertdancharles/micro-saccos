// Pure financial helpers, mirroring the SQL rules in the build plan so the UI can
// preview figures without a round-trip. Money rounds to whole TZS.
//
// Every rate is now a `group_settings` row (migration 020) that 2-of-N admins can
// change, so each helper takes the rate as a trailing argument. The exported
// constants remain the *seeded* values and are used as defaults, which keeps every
// existing caller and test working unchanged — pass the live setting where you have
// it (see hooks/useGroupSettings), fall back to the default where you don't.

// Loan ceilings (whole TZS, floored so we never round above the cap):
//   - 5x the member's contribution (approved savings + paid monthly fees) at the
//     time of request, so a borrower is anchored to what they've put in.
//   - 25% of the current group pool, so one member can't drain it.
// Effective max = the lower of the two; both must hold.
export const POOL_LOAN_FRACTION = 0.25
export const CONTRIBUTION_LOAN_MULTIPLIER = 5
export const LOAN_INTEREST_RATE = 0.05
export const PENALTY_RATE = 0.05

export const poolCeiling = (poolBalance, fraction = POOL_LOAN_FRACTION) =>
  Math.floor(Number(poolBalance) * Number(fraction))

export const contributionCeiling = (contribution, multiplier = CONTRIBUTION_LOAN_MULTIPLIER) =>
  Math.floor(Number(contribution) * Number(multiplier))

export const maxLoan = (contribution, poolBalance, { fraction, multiplier } = {}) =>
  Math.min(contributionCeiling(contribution, multiplier), poolCeiling(poolBalance, fraction))

// Flat monthly interest = principal x rate, whole shillings (Decision #2).
export const monthlyInterest = (principal, rate = LOAN_INTEREST_RATE) =>
  Math.round(Number(principal) * Number(rate))

// Live overdue penalty (Decision #6): simple, rate x base x monthsOverdue, whole TZS.
// `monthsOverdue` is the multiplier the status views expose as penalty_months.
// Note the SQL uses each row's SNAPSHOT penalty_rate, not the current setting, so a
// rate change never restates an existing penalty — pass the row's `penalty_rate`
// when you have it.
export const penaltyDue = (base, monthsOverdue, rate = PENALTY_RATE) =>
  monthsOverdue > 0 ? Math.round(Number(rate) * Number(base) * Number(monthsOverdue)) : 0
