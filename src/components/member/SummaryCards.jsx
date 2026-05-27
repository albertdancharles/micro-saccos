// Member summary cards (build plan §9). 2×2 grid: pool, savings, loan balance,
// amount due (danger-styled when > 0, with the penalty portion called out).
import StatCard from '../ui/StatCard'
import { formatTZS } from '../../lib/format'

export default function SummaryCards({ pool, savings, loan, amountDue, penaltyDue }) {
  const loanBalance = loan?.status === 'active' ? Number(loan.principal) : 0
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
    </div>
  )
}
