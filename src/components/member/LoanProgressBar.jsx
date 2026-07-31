// Loan progress bar (member). One segment per installment, filled when paid.
// Shows next due date below. Renders nothing when there's no active loan.
// UI/UX Pro Max: motion-meaning (segment fill = progress), state clarity
// (paid / part paid / overdue / cancelled / pending), tabular nums.
//
// The segment count is derived, not fixed at three: the term is a group setting
// (020) and a restructure (022) appends further installments.
import { formatDate, formatTZS } from '../../lib/format'
import { useLanguage } from '../../hooks/useLanguage'

export default function LoanProgressBar({ loan, installments }) {
  const { t } = useLanguage()
  if (!loan || loan.status !== 'active' || !installments?.length) return null

  // Cancelled rows are history (early repayment or a restructure), not steps left
  // to take, so they are out of both the count and the "what's next" lookup.
  const live = installments.filter((i) => i.computed_status !== 'cancelled')
  if (!live.length) return null

  const paidCount = live.filter((i) => i.computed_status === 'paid').length
  const nextUnpaid = live.find((i) => i.computed_status !== 'paid')

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <div className="flex items-baseline justify-between mb-3">
        <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">
          {t('Loan progress')}
        </h2>
        <span className="text-xs text-slate-500 tabular-nums">
          {t('{paid} / {total} paid').replace('{paid}', paidCount).replace('{total}', live.length)}
        </span>
      </div>

      <div
        className="flex gap-1.5 mb-3"
        role="progressbar"
        aria-valuenow={paidCount}
        aria-valuemax={live.length}
      >
        {live.map((i) => {
          const paid = i.computed_status === 'paid'
          const overdue = i.computed_status === 'overdue'
          const partial =
            i.computed_status === 'partial' ||
            (overdue && Number(i.interest_paid ?? 0) + Number(i.principal_paid ?? 0) > 0)
          return (
            <div
              key={i.id}
              className={`h-2.5 flex-1 rounded-full transition-colors duration-200 ${
                paid
                  ? 'bg-emerald-500'
                  : partial
                    ? 'bg-sky-400'
                    : overdue
                      ? 'bg-red-300'
                      : 'bg-slate-200'
              }`}
              title={t('Installment {n}: {status}')
                .replace('{n}', i.installment_number)
                .replace('{status}', i.computed_status)}
            />
          )
        })}
      </div>

      {nextUnpaid ? (
        <p className="text-xs text-slate-500 tabular-nums">
          {t('Next: installment {n} · {amount} due {date}')
            .replace('{n}', nextUnpaid.installment_number)
            .replace('{amount}', formatTZS(nextUnpaid.total_with_penalty))
            .replace('{date}', formatDate(nextUnpaid.due_date))}
        </p>
      ) : (
        <p className="text-xs font-medium text-emerald-700">
          {t('All installments paid — loan will close shortly.')}
        </p>
      )}
    </section>
  )
}
