// Approvals queue (build plan §9). Two tabs: pending payments and pending loans.
// UI/UX Pro Max: segmented control with crisp shadow on the active pill, count
// pill ringed to read at a glance, friendly empty-state copy.
import { useState } from 'react'
import LoanQueueItem from './LoanQueueItem'
import PaymentQueueItem from './PaymentQueueItem'
import { supabase } from '../../supabaseClient'
import { useAuth } from '../../hooks/useAuth'
import { useLanguage } from '../../hooks/useLanguage'
import {
  approveMonthlySettlement,
  batchesFrom,
  rejectMonthlySettlement,
} from '../../lib/settlement'
import { formatTZS } from '../../lib/format'
import { fillNames } from '../ui/fillNames'

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

// A monthly settlement waiting for its second admin (049). Without this, what an admin
// settled in one press would land here as thirteen separate signatures. The rows stay
// behind the card so a single one can still be rejected, leaving the rest to sign.
function SettlementBatchCard({ batch, onActioned }) {
  const { t } = useLanguage()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')

  async function run(action, fallback) {
    setError('')
    setBusy(true)
    try {
      await action()
      onActioned?.()
    } catch (err) {
      setError(err?.message || t(fallback))
    } finally {
      setBusy(false)
    }
  }

  const handleSign = () =>
    run(() => approveMonthlySettlement(supabase, batch.batchId), 'Could not sign the settlement.')

  function handleReject() {
    if (!reason.trim()) return setError(t('Add a short reason for the rejection.'))
    return run(
      () => rejectMonthlySettlement(supabase, batch.batchId, reason.trim()),
      'Could not reject the settlement.',
    )
  }

  return (
    <div className="space-y-3 rounded-xl border border-emerald-200/70 bg-emerald-50/40 p-4">
      <div>
        <p className="text-sm font-medium text-slate-900">
          {fillNames(t('Monthly settlement from {name}'), { name: batch.recordedByName })}
        </p>
        <p className="mt-0.5 text-xs text-slate-500 tabular-nums">
          {t('Payments {n} · {amount}')
            .replace('{n}', batch.rows.length)
            .replace('{amount}', formatTZS(batch.total))}
        </p>
      </div>

      {batch.signable === 0 && batch.ownRows === 0 && (
        <p className="rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800 ring-1 ring-inset ring-amber-200/70">
          {t('You have already signed these. Another admin has to finish them.')}
        </p>
      )}
      {batch.ownRows > 0 && (
        <p className="rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800 ring-1 ring-inset ring-amber-200/70">
          {t('Your own payment here needs another admin.')}
        </p>
      )}

      {rejecting ? (
        <div className="space-y-2">
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={2}
            placeholder={t('Reason for rejection')}
            className="input-field"
          />
          {error && <p className="text-sm text-red-600">{error}</p>}
          <div className="flex gap-2">
            <button onClick={handleReject} disabled={busy} className="btn-danger flex-1">
              {busy ? t('Rejecting…') : t('Confirm reject')}
            </button>
            <button
              onClick={() => {
                setRejecting(false)
                setError('')
              }}
              className="btn-secondary flex-1"
            >
              {t('Cancel')}
            </button>
          </div>
        </div>
      ) : (
        <div className="space-y-2">
          {error && <p className="text-sm text-red-600">{error}</p>}
          <div className="flex gap-2">
            <button
              onClick={handleSign}
              disabled={busy || batch.signable === 0}
              className="btn-primary flex-1"
            >
              {busy
                ? t('Signing…')
                : t('Sign all · {amount}').replace('{amount}', formatTZS(batch.signableTotal))}
            </button>
            <button onClick={() => setRejecting(true)} className="btn-secondary">
              {t('Reject all')}
            </button>
          </div>
        </div>
      )}

      <details>
        <summary className="cursor-pointer text-xs font-medium text-slate-600 hover:text-slate-800">
          {t('See each payment')}
        </summary>
        <div className="mt-3 space-y-3">
          {batch.rows.map((s) => (
            <PaymentQueueItem key={s.id} submission={s} onActioned={onActioned} rejectOnly />
          ))}
        </div>
      </details>
    </div>
  )
}

export default function ApprovalsQueue({ pendingLoans, pendingPayments, onActioned }) {
  const { t } = useLanguage()
  const { isOverseer } = useAuth()
  const [tab, setTab] = useState('payments')
  const { batches, loose } = batchesFrom(pendingPayments, { isOverseer })

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-4 sm:p-5 shadow-card">
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
            {batches.map((batch) => (
              <SettlementBatchCard key={batch.batchId} batch={batch} onActioned={onActioned} />
            ))}
            {loose.map((s) => (
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
