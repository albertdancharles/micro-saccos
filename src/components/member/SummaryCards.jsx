// Member summary cards (build plan §9). 2×2 grid of metrics + a full-width
// "Max loan" card showing the 25%-of-pool ceiling (the sole rule, surfaced on the
// dashboard so members know their capacity without opening the loan form).
import StatCard from '../ui/StatCard'
import { formatTZS } from '../../lib/format'
import { contributionCeiling, poolCeiling, maxLoan } from '../../lib/loanMath'

export default function SummaryCards({
  pool,
  outstandingLoans = 0,
  totalAssets = 0,
  savings,
  contribution,
  loan,
  amountDue,
  penaltyDue,
}) {
  // Outstanding loan = remaining principal after any prior repayments.
  // Falls back to principal for older active loans before migration 011.
  const loanBalance =
    loan?.status === 'active'
      ? Number(loan.outstanding_principal ?? loan.principal)
      : 0
  const originalPrincipal = loan?.status === 'active' ? Number(loan.principal) : 0
  const principalRepaid = Math.max(0, originalPrincipal - loanBalance)
  const contribCap = contributionCeiling(contribution)
  const poolCap = poolCeiling(pool)
  const maxLoanAmount = maxLoan(contribution, pool)
  const hasOpenLoan = loan?.status === 'pending' || loan?.status === 'active'
  // Which rule is binding? Helps the member know why the max is what it is.
  const bindingNote =
    maxLoanAmount === 0
      ? contribCap === 0
        ? 'Make a savings deposit or pay your monthly fee to become eligible.'
        : 'Group pool is currently too low to issue a loan.'
      : contribCap < poolCap
        ? 'Limited by 3× your savings + paid fees.'
        : contribCap === poolCap
          ? 'Both rules cap at the same amount.'
          : 'Limited by 25% of the group pool.'

  return (
    <div className="grid grid-cols-2 gap-3">
      <div className="col-span-2 rounded-2xl border border-sky-200 bg-sky-50 p-4">
        <p className="text-xs text-sky-700">Total group assets</p>
        <p className="mt-1 text-2xl font-semibold text-sky-900">{formatTZS(totalAssets)}</p>
        <p className="mt-1 text-xs text-sky-700/80">
          {formatTZS(pool)} in the pool · {formatTZS(outstandingLoans)} out on loans
        </p>
      </div>
      <StatCard label="Group pool" value={formatTZS(pool)} />
      <StatCard label="My savings" value={formatTZS(savings)} />
      <StatCard
        label="My loan balance"
        value={formatTZS(loanBalance)}
        sub={
          loan?.status === 'pending'
            ? 'Request pending'
            : principalRepaid > 0
              ? `Repaid ${formatTZS(principalRepaid)} of ${formatTZS(originalPrincipal)}`
              : undefined
        }
      />
      <StatCard
        label="Amount due"
        value={formatTZS(amountDue)}
        danger={amountDue > 0}
        sub={penaltyDue > 0 ? `Incl. ${formatTZS(penaltyDue)} penalty` : undefined}
      />
      <div className="col-span-2 rounded-2xl border border-emerald-200 bg-emerald-50 p-4">
        <p className="text-xs text-emerald-700">Max loan you can request</p>
        <p className="mt-1 text-2xl font-semibold text-emerald-900">{formatTZS(maxLoanAmount)}</p>
        <p className="mt-1 text-xs text-emerald-700/80">
          {bindingNote}
          {hasOpenLoan && maxLoanAmount > 0
            ? ' Available once your current loan is closed.'
            : ''}
        </p>
      </div>
    </div>
  )
}
