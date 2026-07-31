// Written-off loans that still have people standing behind them (migration 028).
//
// Only appears when there is something to recover. Calling takes money from the
// guarantors' savings, pro-rata across their pledges and capped at each one, so
// the panel shows exactly who pays what before anything happens.
import { useState } from 'react'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { callGuarantees } from '../../lib/guarantors'
import { useLanguage } from '../../hooks/useLanguage'

function LoanRow({ loan, onActioned }) {
  const { t } = useLanguage()
  const [open, setOpen] = useState(false)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  // Mirrors the SQL: each guarantor pays their share of the loss, never more than
  // they pledged. Shown so nobody is surprised by the number afterwards.
  //
  // The loss comes from the earnings ledger, not from outstanding_principal — a
  // written-off loan has its outstanding zeroed, so that field reads 0 here.
  const lost = Number(loan.lossTzs ?? 0)
  const shares = loan.guarantees.map((g) => ({
    ...g,
    share: Math.min(
      Number(g.pledged_amount),
      Math.round((lost * Number(g.pledged_amount)) / (loan.pledgedTotal || 1)),
    ),
  }))
  const recoverable = shares.reduce((s, g) => s + g.share, 0)

  async function handleCall() {
    setError('')
    if (!reason.trim()) return setError(t('A reason is required to call a guarantee.'))
    setBusy(true)
    try {
      await callGuarantees(supabase, loan.id, reason.trim())
      onActioned?.()
    } catch (err) {
      setError(err?.message || t('Could not call the guarantees.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="py-3 space-y-2">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-sm font-medium text-slate-900 truncate">{loan.memberName}</p>
          <p className="text-xs text-slate-500 mt-0.5">
            {t('written off · {n} guarantor(s) pledged {amount}')
              .replace('{n}', loan.guarantees.length)
              .replace('{amount}', formatTZS(loan.pledgedTotal))}
          </p>
        </div>
        <button
          onClick={() => setOpen((v) => !v)}
          disabled={!loan.canCall}
          className="btn-secondary text-xs px-3 py-1.5 shrink-0 disabled:opacity-40"
        >
          {t('Call')}
        </button>
      </div>

      {open && (
        <div className="space-y-2">
          <div className="rounded-lg bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 text-xs space-y-1">
            {shares.map((g) => (
              <div key={g.id} className="flex justify-between">
                <span className="text-slate-600">{g.guarantorName}</span>
                <span className="tabular-nums text-red-700">−{formatTZS(g.share)}</span>
              </div>
            ))}
            <div className="flex justify-between border-t border-slate-200 pt-1 mt-1 font-medium">
              <span className="text-slate-700">{t('Recovered')}</span>
              <span className="tabular-nums text-slate-900">{formatTZS(recoverable)}</span>
            </div>
            <p className="text-slate-500 pt-1">
              {t('The group still absorbs {amount}. No cash moves — savings become loan recovery.')
                .replace('{amount}', formatTZS(Math.max(lost - recoverable, 0)))}
            </p>
          </div>

          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={2}
            placeholder={t('Why are the guarantees being called?')}
            aria-label={t('Reason')}
            className="input-field"
          />
          {error && <p className="text-sm text-red-600">{error}</p>}
          <button onClick={handleCall} disabled={busy} className="btn-danger w-full">
            {busy ? t('Working…') : t('Call the guarantees')}
          </button>
        </div>
      )}
    </div>
  )
}

export default function CallGuaranteesPanel({ callableLoans, onActioned }) {
  const { t } = useLanguage()
  if (!callableLoans || callableLoans.length === 0) return null

  return (
    <section className="rounded-2xl border border-amber-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-amber-700 mb-1">
        {t('Guarantees that can be called ({n})').replace('{n}', callableLoans.length)}
      </h2>
      <p className="text-xs text-slate-500 mb-2">
        {t('These written-off loans were backed by other members.')}
      </p>
      <div className="divide-y divide-slate-100">
        {callableLoans.map((l) => (
          <LoanRow key={l.id} loan={l} onActioned={onActioned} />
        ))}
      </div>
    </section>
  )
}
