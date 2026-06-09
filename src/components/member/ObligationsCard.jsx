// This month's obligations (build plan §9). Refined per UI/UX Pro Max §6:
// tabular nums for money, dividers between rows for scan-ability, status badge
// inline with the amount column. Cancelled installments stay hidden.
import Badge from '../ui/Badge'
import { formatTZS, formatDate } from '../../lib/format'

const monthKey = (s) => (s ? String(s).slice(0, 7) : '')

function ObligationRow({ title, subtitle, penalty, total, status }) {
  return (
    <li className="flex items-start justify-between gap-3 py-3 first:pt-0 last:pb-0">
      <div className="min-w-0">
        <p className="text-sm font-medium text-slate-900">{title}</p>
        {subtitle && <p className="text-xs text-slate-500 mt-0.5">{subtitle}</p>}
        {penalty > 0 && (
          <p className="text-xs text-red-600 mt-1 tabular-nums">+ {formatTZS(penalty)} penalty</p>
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
  const fee = fees.find((f) => monthKey(f.period) === currentMonthKey) || null
  const inst =
    installments.find(
      (i) => monthKey(i.due_date) === currentMonthKey && i.computed_status !== 'cancelled',
    ) || null

  if (!fee && !inst) return null

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-1">
        This month
      </h2>
      <p className="text-xs text-slate-400 mb-3">
        Pay these to keep your account in good standing.
      </p>
      <ul className="divide-y divide-slate-100">
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
