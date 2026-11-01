// The overseer's adjustment to the group pool (AdminSummaryCards holds the only way in).
// Total assets is the pool plus what is out on loans, and loans are not edited here, so
// the two boxes are one number seen twice: type in either and the other follows. Either
// way one delta goes to request_pool_edit, which applies it on the overseer's signature.
import { useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { requestPoolEdit } from '../../lib/admin'
import { useLanguage } from '../../hooks/useLanguage'

// To the cent, as the columns hold it. Subtracting figures with cents leaves float noise
// that would otherwise reach the audit log.
const toCents = (n) => Math.round(n * 100) / 100

// The new pool, or null while the box being typed in is empty.
function newPoolFrom(edit, currentPool, outstanding) {
  if (!edit) return currentPool
  if (edit.value === '') return null
  return toCents(edit.field === 'pool' ? Number(edit.value) : Number(edit.value) - outstanding)
}

function FigureField({ id, label, value, now, onChange }) {
  const { t } = useLanguage()
  return (
    <div>
      <label htmlFor={id} className="block text-sm font-medium text-slate-700 mb-1">
        {label}
      </label>
      <input
        id={id}
        type="number"
        step="any"
        inputMode="decimal"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="input-field tabular-nums"
      />
      <p className="mt-1 text-xs text-slate-500 tabular-nums">
        {t('Now: {amount}').replace('{amount}', formatTZS(now))}
      </p>
    </div>
  )
}

function Form({ stats, onSubmitted, onClose }) {
  const { t } = useLanguage()
  // Only the box being typed in holds what was typed. The other is worked out from it.
  const [edit, setEdit] = useState(null)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const currentPool = Number(stats?.pool ?? 0)
  const outstanding = Number(stats?.outstandingLoans ?? 0)
  const newPool = newPoolFrom(edit, currentPool, outstanding)
  const delta = newPool === null ? 0 : toCents(newPool - currentPool)
  const wouldGoNegative = newPool !== null && newPool < 0

  const poolText = edit?.field === 'pool' ? edit.value : newPool === null ? '' : String(newPool)
  const totalText =
    edit?.field === 'total'
      ? edit.value
      : newPool === null
        ? ''
        : String(toCents(newPool + outstanding))

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (delta === 0) return setError(t('Enter a figure different from today’s.'))
    if (wouldGoNegative) {
      return setError(
        t('This would leave the pool negative ({amount}). Choose a smaller decrease.')
          .replace('{amount}', formatTZS(newPool)),
      )
    }
    if (!reason.trim()) return setError(t('A reason is required for every pool edit.'))
    setBusy(true)
    try {
      await requestPoolEdit(supabase, delta, reason.trim())
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || t('Could not open the pool edit request.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <FigureField
          id="pool-edit-pool"
          label={t('Group pool')}
          value={poolText}
          now={currentPool}
          onChange={(value) => setEdit({ field: 'pool', value })}
        />
        <FigureField
          id="pool-edit-total"
          label={t('Total group assets')}
          value={totalText}
          now={toCents(currentPool + outstanding)}
          onChange={(value) => setEdit({ field: 'total', value })}
        />
      </div>

      <p className="text-xs text-slate-500">
        {t('{amount} is out on loans and stays there, so the pool and total assets move together.')
          .replace('{amount}', formatTZS(outstanding))}
      </p>

      {delta !== 0 && (
        <p
          className={`text-sm font-semibold tabular-nums ${
            wouldGoNegative ? 'text-red-600' : delta > 0 ? 'text-emerald-700' : 'text-slate-900'
          }`}
        >
          {t('Change: {amount}').replace('{amount}', `${delta > 0 ? '+' : ''}${formatTZS(delta)}`)}
        </p>
      )}

      <div>
        <label htmlFor="pool-edit-reason" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Reason')}
        </label>
        <textarea
          id="pool-edit-reason"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={2}
          placeholder={t('e.g. recorded interest from external account, or correction of a deposit mis-entry')}
          className="input-field"
        />
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="rounded-xl bg-amber-50 ring-1 ring-inset ring-amber-200/70 p-3 text-xs text-amber-800">
        {t('This applies at once, on your signature alone, and goes in the audit log. Total assets also set the loan ceiling for every member.')}
      </div>

      <div className="flex gap-2">
        <button type="submit" disabled={busy} className="btn-info flex-1">
          {busy ? t('Submitting…') : t('Apply adjustment')}
        </button>
        <button type="button" onClick={onClose} className="btn-secondary">
          {t('Cancel')}
        </button>
      </div>
    </form>
  )
}

export default function RequestPoolEditModal({ open, onClose, stats, onSubmitted }) {
  const { t } = useLanguage()
  return (
    <Modal open={open} onClose={onClose} title={t('Adjust pool and total assets')}>
      {open && <Form stats={stats} onSubmitted={onSubmitted} onClose={onClose} />}
    </Modal>
  )
}
