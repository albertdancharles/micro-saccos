// Repayment schedule (build plan §9). Every installment: breakdown, total due
// (incl. live penalty), and status, grouped by loan when there is more than one.
// Future pending rows show as "Not due"; cancelled rows (loan closed early) are dimmed
// with a strike. UI/UX Pro Max: divide-y for row separation, tabular nums on money
// columns, status badge in its own column.
import Badge from '../ui/Badge'
import { formatTZS, formatDate } from '../../lib/format'
import { loanLabel } from '../../lib/loans'
import { useLanguage } from '../../hooks/useLanguage'

const monthKey = (s) => (s ? String(s).slice(0, 7) : '')

function ScheduleRow({ installment: i, currentMonthKey }) {
  const { t } = useLanguage()
  const isCancelled = i.computed_status === 'cancelled'
  const isPaid = i.computed_status === 'paid'
  const isFuture = i.computed_status === 'pending' && monthKey(i.due_date) > currentMonthKey
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
}

export default function RepaymentSchedule({ installments, loans = [], currentMonthKey }) {
  const { t } = useLanguage()
  if (!installments.length) return null

  const activeLoans = loans.filter((l) => l.status === 'active')
  const groups =
    activeLoans.length > 1
      ? activeLoans.map((loan) => ({
          key: loan.id,
          heading: loanLabel(loan, t),
          rows: installments.filter((i) => i.loan_id === loan.id),
        }))
      : [{ key: 'only', heading: null, rows: installments }]

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-4 sm:p-5 shadow-card">
      <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-3">
        {t('Repayment schedule')}
      </h2>
      <div className="space-y-4">
        {groups.map((group) => (
          <div key={group.key}>
            {group.heading && (
              <h3 className="text-xs font-medium text-slate-500 mb-2 tabular-nums">
                {group.heading}
              </h3>
            )}
            <ul className="divide-y divide-slate-100">
              {group.rows.map((i) => (
                <ScheduleRow key={i.id} installment={i} currentMonthKey={currentMonthKey} />
              ))}
            </ul>
          </div>
        ))}
      </div>
    </section>
  )
}
