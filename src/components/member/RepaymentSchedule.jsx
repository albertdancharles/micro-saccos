// Repayment schedule (build plan §9). All 3 installments: breakdown, total due
// (incl. live penalty), and status. Future pending rows show as "Not due";
// cancelled rows (loan closed early) are dimmed with a strike. UI/UX Pro Max:
// divide-y for row separation, tabular nums on money columns, status badge in
// its own column.
import Badge from '../ui/Badge'
import { formatTZS, formatDate } from '../../lib/format'
import { useLanguage } from '../../hooks/useLanguage'

const monthKey = (s) => (s ? String(s).slice(0, 7) : '')

export default function RepaymentSchedule({ installments, currentMonthKey }) {
  const { t } = useLanguage()
  if (!installments.length) return null

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-3">
        {t('Repayment schedule')}
      </h2>
      <ul className="divide-y divide-slate-100">
        {installments.map((i) => {
          const isCancelled = i.computed_status === 'cancelled'
          const isPaid = i.computed_status === 'paid'
          const isFuture =
            i.computed_status === 'pending' && monthKey(i.due_date) > currentMonthKey
          const status = isFuture ? 'upcoming' : i.computed_status
          const principalDue = Number(i.principal_due) || 0
          const principalPaid = Number(i.principal_paid) || 0
          const paidSoFar = principalPaid + (Number(i.interest_paid) || 0)
          const breakdown = isPaid
            ? principalPaid > 0
              ? t('Principal + interest')
              : t('Interest')
            : principalDue > 0
              ? t('Principal + interest')
              : t('Interest')
          return (
            <li
              key={i.id}
              className={`flex items-center justify-between gap-3 py-3 first:pt-0 last:pb-0 ${
                isCancelled ? 'opacity-60' : ''
              }`}
            >
              <div className="min-w-0">
                <p
                  className={`text-sm font-medium ${
                    isCancelled ? 'text-slate-500 line-through' : 'text-slate-900'
                  }`}
                >
                  #{i.installment_number} · {breakdown}
                </p>
                <p className="text-xs text-slate-500 mt-0.5">
                  {isCancelled
                    ? t('Cancelled — loan closed early')
                    : t('Due {date}').replace('{date}', formatDate(i.due_date))}
                </p>
                {isPaid && principalPaid > 0 && (
                  <p className="text-xs text-emerald-700 mt-1 tabular-nums">
                    {t('Repaid {amount} principal').replace('{amount}', formatTZS(principalPaid))}
                  </p>
                )}
                {/* Part-settled rows: the money column shows what is STILL owed,
                    so the payment already made needs saying out loud. */}
                {!isPaid && !isCancelled && paidSoFar > 0 && (
                  <p className="text-xs text-sky-700 mt-1 tabular-nums">
                    {t('{amount} already paid').replace('{amount}', formatTZS(paidSoFar))}
                  </p>
                )}
              </div>
              <div className="text-right shrink-0">
                {!isCancelled && (
                  <p className="text-sm font-semibold text-slate-900 tabular-nums">
                    {formatTZS(i.total_with_penalty)}
                  </p>
                )}
                {Number(i.penalty_due) > 0 && !isCancelled && (
                  <p className="text-xs text-red-600 mt-0.5 tabular-nums">
                    + {formatTZS(i.penalty_due)}
                  </p>
                )}
              </div>
              <div className="w-20 text-right shrink-0">
                <Badge status={status} />
              </div>
            </li>
          )
        })}
      </ul>
    </section>
  )
}
