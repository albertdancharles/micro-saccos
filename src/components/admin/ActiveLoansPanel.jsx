// Active loans, riskiest first (migration 022). `risk` comes from v_loan_risk,
// which derives non-performance from the installment record — two or more overdue
// installments — so it is always current and never needs an admin to set a flag.
import { useState } from 'react'
import { formatTZS } from '../../lib/format'
import { useLanguage } from '../../hooks/useLanguage'
import RequestLoanActionModal from './RequestLoanActionModal'

function LoanRow({ loan, onAction }) {
  const { t } = useLanguage()
  const atRisk = !!loan.risk

  return (
    <div className="flex items-center justify-between gap-3 py-3">
      <div className="min-w-0">
        <p className="text-sm font-medium text-slate-900 truncate">{loan.memberName}</p>
        <p className="text-xs text-slate-500 mt-0.5">
          {atRisk
            ? t('{n} overdue · {d} days')
                .replace('{n}', loan.risk.overdue_installments)
                .replace('{d}', loan.risk.days_overdue)
            : t('On schedule')}
        </p>
      </div>

      <div className="flex items-center gap-3 shrink-0">
        <div className="text-right">
          <p
            className={`text-sm font-semibold tabular-nums ${
              atRisk ? 'text-red-700' : 'text-slate-900'
            }`}
          >
            {formatTZS(loan.outstanding)}
          </p>
          {atRisk && loan.risk.penalty_accrued > 0 && (
            <p className="text-[11px] text-red-600 tabular-nums">
              {t('+ {amount} penalty').replace(
                '{amount}',
                formatTZS(loan.risk.penalty_accrued),
              )}
            </p>
          )}
        </div>

        {loan.hasOpenAction ? (
          <span className="text-[11px] text-amber-700 whitespace-nowrap">{t('Action pending')}</span>
        ) : (
          <button
            onClick={() => onAction(loan)}
            disabled={!loan.canAction}
            className="btn-secondary text-xs px-3 py-1.5 disabled:opacity-40"
          >
            {t('Action')}
          </button>
        )}
      </div>
    </div>
  )
}

export default function ActiveLoansPanel({ activeLoans, onActioned }) {
  const { t } = useLanguage()
  const [target, setTarget] = useState(null)

  if (!activeLoans || activeLoans.length === 0) return null
  const atRiskCount = activeLoans.filter((l) => l.risk).length

  return (
    <section className="rounded-2xl border border-slate-200/80 bg-white p-4 sm:p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <div className="flex items-baseline justify-between mb-1">
        <h2 className="text-[13px] font-semibold tracking-tight text-slate-700">
          {t('Active loans ({n})').replace('{n}', activeLoans.length)}
        </h2>
        {atRiskCount > 0 && (
          <span className="text-[11px] font-medium text-red-700">
            {t('{n} at risk').replace('{n}', atRiskCount)}
          </span>
        )}
      </div>

      <div className="divide-y divide-slate-100">
        {activeLoans.map((l) => (
          <LoanRow key={l.id} loan={l} onAction={setTarget} />
        ))}
      </div>

      <RequestLoanActionModal
        open={!!target}
        loan={target}
        onClose={() => setTarget(null)}
        onSubmitted={onActioned}
      />
    </section>
  )
}
