// Pure financial helpers, mirroring the SQL rules in the build plan so the UI can
// preview figures without a round-trip. Money rounds to whole TZS.
//
// Every rate is now a `group_settings` row (migration 020) that 2-of-N admins can
// change, so each helper takes the rate as a trailing argument. The exported
// constants remain the *seeded* values and are used as defaults, which keeps every
// existing caller and test working unchanged — pass the live setting where you have
// it (see hooks/useGroupSettings), fall back to the default where you don't.

// Loan ceilings (whole TZS, floored so we never round above the cap):
//   - 5x the member's contribution at the time of request, so a borrower is
//     anchored to what they've put in. Contribution IS savings, and savings is the
//     three-term sum in lib/savings.js getApprovedSavings: approved deposits +
//     monthly_fees.amount_paid across every row + approved savings_adjustments.
//     Migration 047 made `approve_loan` read the same three (via member_savings());
//     before it, the RPC counted only deposits and fully-paid fees, so a balance
//     recorded as an adjustment was worth nothing at the approval desk.
//   - 25% of TOTAL GROUP ASSETS — the pool plus everything out on loan — so one
//     member can't take a disproportionate share of the group.
// Effective max = the lower of the two; both must hold.
//
// ASSETS, NOT THE POOL (migration 045). The pool already has every active loan
// subtracted, so measuring the cap against it made a member's ceiling depend on
// how much the group had lent to other people that morning: the same amount was
// allowed at the top of a meeting's agenda and refused at the bottom. Assets do
// not move when a loan is disbursed, so the ceiling holds still all meeting.
// `pool_loan_fraction` keeps its key — it is a group_settings row and renaming
// it would orphan the group's voted value — but it is a fraction of assets now.
//
// Whether the group can actually HAND OVER the money is a separate question that
// only approve_loan answers, against the pool. These helpers are for display.
export const POOL_LOAN_FRACTION = 0.25
export const CONTRIBUTION_LOAN_MULTIPLIER = 5
export const LOAN_INTEREST_RATE = 0.05
export const PENALTY_RATE = 0.05

export const assetsCeiling = (totalAssets, fraction = POOL_LOAN_FRACTION) =>
  Math.floor(Number(totalAssets) * Number(fraction))

export const contributionCeiling = (contribution, multiplier = CONTRIBUTION_LOAN_MULTIPLIER) =>
  Math.floor(Number(contribution) * Number(multiplier))

export const maxLoan = (contribution, totalAssets, { fraction, multiplier } = {}) =>
  Math.min(contributionCeiling(contribution, multiplier), assetsCeiling(totalAssets, fraction))

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
