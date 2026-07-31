// Payment allocation — a pure mirror of the waterfall in approve_submission
// (migration 021), so the admin can see exactly where a payment will land before
// approving it, without a round-trip.
//
// The SQL is authoritative. These helpers exist to preview it and are unit-tested
// against the same rules:
//
//   monthly fee        penalty → base
//   loan installment   penalty → interest → contracted principal → extra principal
//
// Penalty is always retired first: it is the borrower's most expensive debt, and
// paying principal while a penalty compounds costs the member money.
//
// Money is whole TZS. `excess` is what could not be allocated to anything — the
// RPC refuses a payment with a positive excess rather than booking it as a mystery
// penalty, so the UI should surface it as an error before the admin submits.

const clamp = (n) => Math.max(0, Number(n) || 0)

// fee: { amount, amount_paid, penalty_due }
export function allocateFeePayment(payment, fee) {
  let left = clamp(payment)
  const penaltyOwed = clamp(fee.penalty_due)
  const baseOwed = clamp(clamp(fee.amount) - clamp(fee.amount_paid))

  const penalty = Math.min(left, penaltyOwed)
  left -= penalty

  const base = Math.min(left, baseOwed)
  left -= base

  const remaining = baseOwed - base
  return {
    penalty,
    base,
    excess: left,
    remaining,
    owed: penaltyOwed + baseOwed,
    status: remaining <= 0 ? 'paid' : 'partial',
  }
}

// installment: { interest_due, interest_paid, principal_due, principal_paid, penalty_due }
// outstanding: the loan's current outstanding_principal — the ceiling on how much
// principal this payment can retire, including early repayment beyond principal_due.
export function allocateInstallmentPayment(payment, installment, outstanding) {
  let left = clamp(payment)
  const penaltyOwed = clamp(installment.penalty_due)
  const interestOwed = clamp(clamp(installment.interest_due) - clamp(installment.interest_paid))
  // principal_paid can exceed principal_due after an early repayment, so this is
  // clamped rather than allowed to go negative.
  const principalOwed = clamp(clamp(installment.principal_due) - clamp(installment.principal_paid))
  const outstandingNow = clamp(outstanding)

  const penalty = Math.min(left, penaltyOwed)
  left -= penalty

  const interest = Math.min(left, interestOwed)
  left -= interest

  const principal = Math.min(left, principalOwed)
  left -= principal

  const extraPrincipal = Math.min(left, clamp(outstandingNow - principal))
  left -= extraPrincipal

  const interestRemaining = interestOwed - interest
  const principalRemaining = principalOwed - principal
  const settled = interestRemaining <= 0 && principalRemaining <= 0

  return {
    penalty,
    interest,
    principal,
    extraPrincipal,
    excess: left,
    remaining: interestRemaining + principalRemaining,
    owed: penaltyOwed + interestOwed + principalOwed,
    // The most this payment could ever settle — the RPC rejects anything above it.
    ceiling: penaltyOwed + interestOwed + outstandingNow,
    outstandingAfter: clamp(outstandingNow - principal - extraPrincipal),
    status: settled ? 'paid' : 'partial',
  }
}

// Shared by the member obligation cards and the admin queue: "paid 6,000 of 10,500".
export function progressOf(row) {
  const total = clamp(row?.total_with_penalty)
  const paid =
    clamp(row?.amount_paid) + clamp(row?.interest_paid) + clamp(row?.principal_paid)
  return { paid, total, isPartial: paid > 0 && total > 0 }
}
