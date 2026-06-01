// This month's obligations (build plan §9). The current fee + the installment due
// this month, each with a status badge and the penalty portion when overdue.
import Badge from '../ui/Badge'
import { formatTZS, formatDate } from '../../lib/format'

const monthKey = (s) => (s ? String(s).slice(0, 7) : '')

function ObligationRow({ title, subtitle, penalty, total, status }) {
  return (
    <li className="flex items-start justify-between gap-3">
      <div>
        <p className="text-sm text-gray-900">{title}</p>
        {subtitle && <p className="text-xs text-gray-400">{subtitle}</p>}
        {penalty > 0 && <p className="text-xs text-red-600">+ {formatTZS(penalty)} penalty</p>}
      </div>
      <div className="text-right shrink-0">
        <p className="text-sm font-medium text-gray-900">{formatTZS(total)}</p>
        <Badge status={status} />
      </div>
    </li>
  )
}

export default function ObligationsCard({ fees, installments, currentMonthKey }) {
  const fee = fees.find((f) => monthKey(f.period) === currentMonthKey) || null
  // Cancelled installments (loan closed early) are historical, not obligations.
  const inst =
    installments.find(
      (i) => monthKey(i.due_date) === currentMonthKey && i.computed_status !== 'cancelled',
    ) || null

  if (!fee && !inst) return null

  return (
    <section className="rounded-2xl border border-gray-100 bg-white p-4">
      <h2 className="text-sm font-semibold text-gray-900 mb-3">This month</h2>
      <ul className="space-y-3">
        {fee && (
          <ObligationRow
            title="Membership fee"
            penalty={Number(fee.penalty_due)}
            total={Number(fee.total_with_penalty)}
            status={fee.computed_status}
          />
        )}
        {inst && (
          <ObligationRow
            title={`Loan installment ${inst.installment_number}`}
            subtitle={`${Number(inst.principal_due) > 0 ? 'Principal + interest' : 'Interest'} · due ${formatDate(inst.due_date)}`}
            penalty={Number(inst.penalty_due)}
            total={Number(inst.total_with_penalty)}
            status={inst.computed_status}
          />
        )}
      </ul>
    </section>
  )
}
