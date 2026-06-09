// Loan progress bar (member). Three segments, one per installment, filled when
// paid. Shows next due date below. Renders nothing when there's no active loan.
// UI/UX Pro Max: motion-meaning (segment fill = progress), state clarity
// (paid / overdue / cancelled / pending), tabular nums.
import { formatDate, formatTZS } from '../../lib/format'

export default function LoanProgressBar({ loan, installments }) {
  if (!loan || loan.status !== 'active' || !installments?.length) return null

  const paidCount = installments.filter((i) => i.computed_status === 'paid').length
  const nextUnpaid = installments.find((i) => i.computed_status !== 'paid')

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <div className="flex items-baseline justify-between mb-3">
        <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">
          Loan progress
        </h2>
        <span className="text-xs text-slate-500 tabular-nums">
          {paidCount} / {installments.length} paid
        </span>
      </div>

      <div
        className="grid grid-cols-3 gap-1.5 mb-3"
        role="progressbar"
        aria-valuenow={paidCount}
        aria-valuemax={installments.length}
      >
        {installments.map((i) => {
          const paid = i.computed_status === 'paid'
          const overdue = i.computed_status === 'overdue'
          const cancelled = i.computed_status === 'cancelled'
          return (
            <div
              key={i.id}
              className={`h-2.5 rounded-full transition-colors duration-200 ${
                paid
                  ? 'bg-emerald-500'
                  : overdue
                    ? 'bg-red-300'
                    : cancelled
                      ? 'bg-slate-200/60'
                      : 'bg-slate-200'
              }`}
              title={`Installment ${i.installment_number}: ${i.computed_status}`}
            />
          )
        })}
      </div>

      {nextUnpaid ? (
        <p className="text-xs text-slate-500 tabular-nums">
          Next: installment {nextUnpaid.installment_number} ·{' '}
          {formatTZS(nextUnpaid.total_with_penalty)} due {formatDate(nextUnpaid.due_date)}
        </p>
      ) : (
        <p className="text-xs font-medium text-emerald-700">
          All installments paid — loan will close shortly.
        </p>
      )}
    </section>
  )
}
