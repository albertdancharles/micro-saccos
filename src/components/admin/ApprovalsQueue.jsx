// Approvals queue (build plan §9). Two tabs: pending payments and pending loans.
// UI/UX Pro Max: segmented control with crisp shadow on the active pill, count
// pill ringed to read at a glance, friendly empty-state copy.
import { useState } from 'react'
import LoanQueueItem from './LoanQueueItem'
import PaymentQueueItem from './PaymentQueueItem'
import { useLanguage } from '../../hooks/useLanguage'

function TabButton({ active, onClick, children, count }) {
  return (
    <button
      onClick={onClick}
      className={`flex-1 rounded-lg py-2 text-sm font-medium transition-all duration-150 ${
        active
          ? 'bg-white text-slate-900 shadow-[0_1px_2px_rgba(15,23,42,0.06),0_1px_3px_rgba(15,23,42,0.10)]'
          : 'text-slate-500 hover:text-slate-700'
      }`}
      aria-pressed={active}
    >
      <span className="inline-flex items-center gap-1.5">
        {children}
        <span
          className={`inline-flex min-w-5 items-center justify-center rounded-full px-1.5 text-[10px] font-semibold tabular-nums ring-1 ring-inset ${
            active
              ? count > 0
                ? 'bg-amber-50 text-amber-700 ring-amber-200'
                : 'bg-slate-100 text-slate-500 ring-slate-200'
              : 'bg-transparent text-slate-400 ring-slate-200'
          }`}
        >
          {count}
        </span>
      </span>
    </button>
  )
}

export default function ApprovalsQueue({ pendingLoans, pendingPayments, onActioned }) {
  const { t } = useLanguage()
  const [tab, setTab] = useState('payments')

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-4 sm:p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-3">
        {t('Approvals')}
      </h2>

      <div className="flex gap-1 rounded-xl bg-slate-100/80 p-1 mb-4" role="tablist">
        <TabButton
          active={tab === 'payments'}
          onClick={() => setTab('payments')}
          count={pendingPayments.length}
        >
          {t('Payments')}
        </TabButton>
        <TabButton
          active={tab === 'loans'}
          onClick={() => setTab('loans')}
          count={pendingLoans.length}
        >
          {t('Loans')}
        </TabButton>
      </div>

      {tab === 'payments' ? (
        pendingPayments.length ? (
          <div className="space-y-3">
            {pendingPayments.map((s) => (
              <PaymentQueueItem key={s.id} submission={s} onActioned={onActioned} />
            ))}
          </div>
        ) : (
          <p className="text-sm text-slate-400 text-center py-8">
            {t('All caught up — no payments awaiting review.')}
          </p>
        )
      ) : pendingLoans.length ? (
        <div className="space-y-3">
          {pendingLoans.map((l) => (
            <LoanQueueItem key={l.id} loan={l} onActioned={onActioned} />
          ))}
        </div>
      ) : (
        <p className="text-sm text-slate-400 text-center py-8">
          {t('No loan requests awaiting review.')}
        </p>
      )}
    </section>
  )
}
