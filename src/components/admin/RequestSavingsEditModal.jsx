// Open a savings-edit request for a member. Admins can target any non-admin
// member or themselves; the DB rejects requests against another admin. The
// requester's vote does NOT auto-count toward the threshold (the "other admins
// must approve" rule), so this opens at 0/N and waits for other admins.
import { useState } from 'react'
import Modal from '../ui/Modal'
import DirectionToggle from '../ui/DirectionToggle'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { requestSavingsEdit } from '../../lib/admin'
import { useLanguage } from '../../hooks/useLanguage'

function Form({ target, onSubmitted, onClose }) {
  const { t } = useLanguage()
  const [direction, setDirection] = useState('increase')
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const amountNum = Number(amount)
  const delta = direction === 'increase' ? amountNum : -amountNum
  const previewSavings = (Number(target.savings) || 0) + delta
  const wouldGoNegative = previewSavings < 0

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!(amountNum > 0)) return setError(t('Enter an amount greater than zero.'))
    if (!reason.trim()) return setError(t('A reason is required for every savings edit.'))
    if (wouldGoNegative) {
      return setError(
        t('This would leave {name} with a negative balance ({amount}).')
          .replace('{name}', target.name)
          .replace('{amount}', formatTZS(previewSavings)),
      )
    }
    setBusy(true)
    try {
      await requestSavingsEdit(supabase, target.id, delta, reason.trim())
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || t('Could not open the savings edit request.'))
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
          <span className="text-slate-500">{t('Current savings')}</span>
          <span className="text-slate-900 tabular-nums">{formatTZS(target.savings)}</span>
        </div>
      </div>

      <DirectionToggle direction={direction} onChange={setDirection} />

      <div>
        <label htmlFor="savings-edit-amount" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Amount (TSh)')}
        </label>
        <input
          id="savings-edit-amount"
          type="number"
          min="0"
          inputMode="numeric"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          placeholder="0"
          className="input-field tabular-nums"
        />
        {amountNum > 0 && (
          <p
            className={`mt-1 text-xs tabular-nums ${
              wouldGoNegative ? 'text-red-600' : 'text-slate-500'
            }`}
          >
            {t('New savings would be {amount}.').replace('{amount}', formatTZS(previewSavings))}
          </p>
        )}
      </div>

      <div>
        <label htmlFor="savings-edit-reason" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Reason')}
        </label>
        <textarea
          id="savings-edit-reason"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={2}
          placeholder={t('e.g. correction of a missed deposit on 2026-04-15')}
          className="input-field"
        />
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="rounded-xl bg-amber-50 ring-1 ring-inset ring-amber-200/70 p-3 text-xs text-amber-800">
        {t("Two other admins must approve this edit before it applies. You can't approve your own request.")}
      </div>

      <div className="flex gap-2">
        <button type="submit" disabled={busy} className="btn-primary flex-1">
          {busy ? t('Submitting…') : t('Submit edit')}
        </button>
        <button type="button" onClick={onClose} className="btn-secondary">
          {t('Cancel')}
        </button>
      </div>
    </form>
  )
}

export default function RequestSavingsEditModal({ open, onClose, target, onSubmitted }) {
  const { t } = useLanguage()
  return (
    <Modal open={open} onClose={onClose} title={t('Edit member savings')}>
      {open && target && <Form target={target} onSubmitted={onSubmitted} onClose={onClose} />}
    </Modal>
  )
}
