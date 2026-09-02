// This month's obligations (build plan §9). Refined per UI/UX Pro Max §6:
// tabular nums for money, dividers between rows for scan-ability, status badge
// inline with the amount column. Cancelled installments stay hidden.
import Badge from '../ui/Badge'
import { formatTZS, formatDate } from '../../lib/format'
import { useLanguage } from '../../hooks/useLanguage'

const monthKey = (s) => (s ? String(s).slice(0, 7) : '')

function ObligationRow({ title, subtitle, penalty, total, status, paid = 0 }) {
  const { t } = useLanguage()
  return (
    <li className="flex items-start justify-between gap-3 py-3 first:pt-0 last:pb-0">
      <div className="min-w-0">
        <p className="text-sm font-medium text-slate-900">{title}</p>
        {subtitle && <p className="text-xs text-slate-500 mt-0.5">{subtitle}</p>}
        {/* With partial payments the headline figure is what is STILL owed, so a
            member who has part-paid needs to see their payment acknowledged. */}
        {paid > 0 && (
          <p className="text-xs text-sky-700 mt-1 tabular-nums">
            {t('{amount} already paid').replace('{amount}', formatTZS(paid))}
          </p>
        )}
        {penalty > 0 && (
          <p className="text-xs text-red-600 mt-1 tabular-nums">
            {t('+ {penalty} penalty').replace('{penalty}', formatTZS(penalty))}
          </p>
        )}
      </div>
      <div className="text-right shrink-0 flex flex-col items-end gap-1">
        <p className="text-sm font-semibold text-slate-900 tabular-nums">{formatTZS(total)}</p>
        <Badge status={status} />
      </div>
    </li>
  )
}

export default function ObligationsCard({ fees, installments, currentMonthKey }) {
  const { t } = useLanguage()
  const fee = fees.find((f) => monthKey(f.period) === currentMonthKey) || null
  const inst =
    installments.find(
      (i) => monthKey(i.due_date) === currentMonthKey && i.computed_status !== 'cancelled',
    ) || null

  if (!fee && !inst) return null

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-4 sm:p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-1">
        {t('This month')}
      </h2>
      <p className="text-xs text-slate-400 mb-3">
        {t('Pay these to keep your account in good standing.')}
      </p>
      <ul className="divide-y divide-slate-100">
        {fee && (
          <ObligationRow
            title={t('Membership fee')}
            penalty={Number(fee.penalty_due)}
            total={Number(fee.total_with_penalty)}
            paid={Number(fee.amount_paid ?? 0)}
            status={fee.computed_status}
          />
        )}
        {inst && (
          <ObligationRow
            title={t('Loan installment {n}').replace('{n}', inst.installment_number)}
            subtitle={`${Number(inst.principal_due) > 0 ? t('Principal + interest') : t('Interest')} · ${t('due')} ${formatDate(inst.due_date)}`}
            penalty={Number(inst.penalty_due)}
            total={Number(inst.total_with_penalty)}
            paid={Number(inst.interest_paid ?? 0) + Number(inst.principal_paid ?? 0)}
            status={inst.computed_status}
          />
        )}
      </ul>
    </section>
  )
}
