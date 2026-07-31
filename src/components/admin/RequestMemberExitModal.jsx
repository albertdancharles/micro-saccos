// Settle a member and remove them from the group (migration 025).
//
// Deliberately NOT deletion. Exit opens a withdrawal for everything they are still
// owed; when that payout is recorded they are deactivated and every fee, loan and
// repayment they were part of stays on record, so closed cycles still reconcile.
import { useEffect, useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { getWithdrawable, requestMemberExit } from '../../lib/withdrawals'
import { useLanguage } from '../../hooks/useLanguage'

function Form({ target, onSubmitted, onClose }) {
  const { t } = useLanguage()
  const [limits, setLimits] = useState(null)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    let cancelled = false
    getWithdrawable(supabase, target.id)
      .then((l) => {
        if (!cancelled) setLimits(l)
      })
      .catch((e) => {
        if (!cancelled) setError(e?.message || t('Could not work out their settlement.'))
      })
    return () => {
      cancelled = true
    }
  }, [target.id]) // eslint-disable-line react-hooks/exhaustive-deps

  const outstanding = Number(limits?.outstanding_tzs ?? 0)
  const settlement = Number(limits?.withdrawable_tzs ?? 0)
  const blocked = outstanding > 0

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!reason.trim()) return setError(t('A reason is required to exit a member.'))
    setBusy(true)
    try {
      await requestMemberExit(supabase, target.id, reason.trim())
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || t('Could not open the exit request.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div className="rounded-xl bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 text-sm space-y-1">
        <div className="flex justify-between">
          <span className="text-slate-500">{t('Member')}</span>
          <span className="text-slate-900">{target.name}</span>
        </div>
        <div className="flex justify-between">
          <span className="text-slate-500">{t('Settlement')}</span>
          <span className="font-semibold text-slate-900 tabular-nums">
            {limits ? formatTZS(settlement) : '—'}
          </span>
        </div>
        {outstanding > 0 && (
          <div className="flex justify-between">
            <span className="text-slate-500">{t('Still owes')}</span>
            <span className="font-semibold text-red-700 tabular-nums">
              {formatTZS(outstanding)}
            </span>
          </div>
        )}
      </div>

      {blocked ? (
        <p className="rounded-xl bg-red-50 ring-1 ring-inset ring-red-200/70 p-3 text-xs text-red-800">
          {t('They cannot leave with an open loan. Settle it, recover it from their savings, or write it off first.')}
        </p>
      ) : (
        <p className="rounded-xl bg-amber-50 ring-1 ring-inset ring-amber-200/70 p-3 text-xs text-amber-800">
          {t('This opens a withdrawal for their full balance. Once two admins approve and the payout is recorded, they leave the group — their history is kept.')}
        </p>
      )}

      <div>
        <label htmlFor="exit-reason" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Reason')}
        </label>
        <textarea
          id="exit-reason"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={2}
          placeholder={t('e.g. moving to Mwanza; leaving the group at the end of the cycle')}
          className="input-field"
        />
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="flex gap-2">
        <button type="submit" disabled={busy || blocked || !limits} className="btn-primary flex-1">
          {busy ? t('Submitting…') : t('Open exit settlement')}
        </button>
        <button type="button" onClick={onClose} className="btn-secondary">
          {t('Cancel')}
        </button>
      </div>
    </form>
  )
}

export default function RequestMemberExitModal({ open, target, onClose, onSubmitted }) {
  const { t } = useLanguage()
  return (
    <Modal open={open} onClose={onClose} title={t('Settle & exit member')}>
      {open && target && <Form target={target} onSubmitted={onSubmitted} onClose={onClose} />}
    </Modal>
  )
}
