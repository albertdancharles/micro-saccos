// Loan progress bar (member). Three segments, one per installment, filled when
// paid. Shows next due date below. Renders nothing when there's no active loan.
import { formatDate, formatTZS } from '../../lib/format'

export default function LoanProgressBar({ loan, installments }) {
  if (!loan || loan.status !== 'active' || !installments?.length) return null

  const paidCount = installments.filter((i) => i.computed_status === 'paid').length
  const nextUnpaid = installments.find((i) => i.computed_status !== 'paid')

  return (
    <section className="rounded-2xl border border-gray-100 bg-white p-4">
      <div className="flex items-baseline justify-between mb-3">
        <h2 className="text-sm font-semibold text-gray-900">Loan progress</h2>
        <span className="text-xs text-gray-500">
          {paidCount}/{installments.length} installments paid
        </span>
      </div>

      <div className="grid grid-cols-3 gap-1 mb-3">
        {installments.map((i) => {
          const paid = i.computed_status === 'paid'
          const overdue = i.computed_status === 'overdue'
          return (
            <div
              key={i.id}
              className={`h-3 rounded-full ${
                paid ? 'bg-emerald-500' : overdue ? 'bg-red-300' : 'bg-gray-200'
              }`}
              title={`Installment ${i.installment_number}: ${i.computed_status}`}
            />
          )
        })}
      </div>

      {nextUnpaid ? (
        <p className="text-xs text-gray-500">
          Next: installment {nextUnpaid.installment_number} ·{' '}
          {formatTZS(nextUnpaid.total_with_penalty)} due {formatDate(nextUnpaid.due_date)}
        </p>
      ) : (
        <p className="text-xs text-emerald-600">All installments paid — loan will close shortly.</p>
      )}
    </section>
  )
}
