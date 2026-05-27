// Repayment schedule (build plan §9). All 3 installments: breakdown, total due
// (incl. live penalty), and status. Future pending rows show as "Not due".
import Badge from '../ui/Badge'
import { formatTZS, formatDate } from '../../lib/format'

const monthKey = (s) => (s ? String(s).slice(0, 7) : '')

export default function RepaymentSchedule({ installments, currentMonthKey }) {
  if (!installments.length) return null

  return (
    <section className="rounded-2xl border border-gray-100 bg-white p-4">
      <h2 className="text-sm font-semibold text-gray-900 mb-3">Repayment schedule</h2>
      <div className="space-y-2">
        {installments.map((i) => {
          const isFuture = i.computed_status === 'pending' && monthKey(i.due_date) > currentMonthKey
          const status = isFuture ? 'upcoming' : i.computed_status
          const breakdown = Number(i.principal_due) > 0 ? 'Principal + interest' : 'Interest'
          return (
            <div
              key={i.id}
              className="flex items-center justify-between gap-3 border-b border-gray-50 pb-2 last:border-0 last:pb-0"
            >
              <div className="min-w-0">
                <p className="text-sm text-gray-900">
                  #{i.installment_number} · {breakdown}
                </p>
                <p className="text-xs text-gray-400">Due {formatDate(i.due_date)}</p>
              </div>
              <div className="text-right shrink-0">
                <p className="text-sm font-medium text-gray-900">{formatTZS(i.total_with_penalty)}</p>
                {Number(i.penalty_due) > 0 && (
                  <p className="text-xs text-red-600">+ {formatTZS(i.penalty_due)}</p>
                )}
              </div>
              <div className="w-16 text-right shrink-0">
                <Badge status={status} />
              </div>
            </div>
          )
        })}
      </div>
    </section>
  )
}
