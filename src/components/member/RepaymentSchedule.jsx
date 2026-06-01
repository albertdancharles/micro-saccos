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
          const isCancelled = i.computed_status === 'cancelled'
          const isPaid = i.computed_status === 'paid'
          const isFuture =
            i.computed_status === 'pending' && monthKey(i.due_date) > currentMonthKey
          const status = isFuture ? 'upcoming' : i.computed_status
          const principalDue = Number(i.principal_due) || 0
          const principalPaid = Number(i.principal_paid) || 0
          // Label shows what this installment actually covered: paid principal
          // for completed installments, or due principal for pending ones.
          const breakdown = isPaid
            ? principalPaid > 0
              ? 'Principal + interest'
              : 'Interest'
            : principalDue > 0
              ? 'Principal + interest'
              : 'Interest'
          return (
            <div
              key={i.id}
              className={`flex items-center justify-between gap-3 border-b border-gray-50 pb-2 last:border-0 last:pb-0 ${
                isCancelled ? 'opacity-60' : ''
              }`}
            >
              <div className="min-w-0">
                <p className={`text-sm ${isCancelled ? 'text-gray-500 line-through' : 'text-gray-900'}`}>
                  #{i.installment_number} · {breakdown}
                </p>
                <p className="text-xs text-gray-400">
                  {isCancelled
                    ? 'Cancelled — loan closed early'
                    : `Due ${formatDate(i.due_date)}`}
                </p>
                {isPaid && principalPaid > 0 && (
                  <p className="text-xs text-emerald-700">
                    Repaid {formatTZS(principalPaid)} principal
                  </p>
                )}
              </div>
              <div className="text-right shrink-0">
                {!isCancelled && (
                  <p className="text-sm font-medium text-gray-900">{formatTZS(i.total_with_penalty)}</p>
                )}
                {Number(i.penalty_due) > 0 && !isCancelled && (
                  <p className="text-xs text-red-600">+ {formatTZS(i.penalty_due)}</p>
                )}
              </div>
              <div className="w-20 text-right shrink-0">
                <Badge status={status} />
              </div>
            </div>
          )
        })}
      </div>
    </section>
  )
}
