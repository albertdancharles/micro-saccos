// Member summary cards (build plan §9). 2×2 grid of metrics + a full-width
// "Max loan" card showing the 25%-of-pool ceiling (the sole rule, surfaced on the
// dashboard so members know their capacity without opening the loan form).
import StatCard from '../ui/StatCard'
import { formatTZS } from '../../lib/format'
import { maxLoan } from '../../lib/loanMath'

export default function SummaryCards({ pool, savings, loan, amountDue, penaltyDue }) {
  const loanBalance = loan?.status === 'active' ? Number(loan.principal) : 0
  const maxLoanAmount = maxLoan(pool)
  const hasOpenLoan = loan?.status === 'pending' || loan?.status === 'active'

  return (
    <div className="grid grid-cols-2 gap-3">
      <StatCard label="Group pool" value={formatTZS(pool)} />
      <StatCard label="My savings" value={formatTZS(savings)} />
      <StatCard
        label="My loan balance"
        value={formatTZS(loanBalance)}
        sub={loan?.status === 'pending' ? 'Request pending' : undefined}
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
          25% of the current group pool
          {hasOpenLoan ? ' · available once your current loan is closed' : ''}.
        </p>
      </div>
    </div>
  )
}
