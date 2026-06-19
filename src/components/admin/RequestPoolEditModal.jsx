// Open a group-pool edit (admin-only). Adjusts the group pool (and thus total
// assets) by a positive or negative delta. The requester's vote does NOT
// auto-count; two OTHER admins must approve.
import { useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { requestPoolEdit } from '../../lib/admin'
import { useLanguage } from '../../hooks/useLanguage'

function DirectionToggle({ direction, onChange }) {
  const { t } = useLanguage()
  const opts = [
    {
      key: 'increase',
      label: t('Increase'),
      active: 'border-emerald-500 bg-emerald-50 text-emerald-700 ring-emerald-200',
    },
    {
      key: 'decrease',
      label: t('Decrease'),
      active: 'border-red-500 bg-red-50 text-red-700 ring-red-200',
    },
  ]
  return (
    <div className="grid grid-cols-2 gap-2">
      {opts.map((o) => (
        <button
          key={o.key}
          type="button"
          onClick={() => onChange(o.key)}
          className={`rounded-xl border px-3 py-2.5 text-sm font-medium transition-all duration-150 ${
            direction === o.key
              ? `${o.active} ring-1`
              : 'border-slate-200 text-slate-600 hover:border-slate-300'
          }`}
        >
          {o.label}
        </button>
      ))}
    </div>
  )
}

function Form({ stats, onSubmitted, onClose }) {
  const { t } = useLanguage()
  const [direction, setDirection] = useState('increase')
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const amountNum = Number(amount)
  const delta = direction === 'increase' ? amountNum : -amountNum
  const previewPool = Number(stats?.pool ?? 0) + delta
  const previewTotal = Number(stats?.totalAssets ?? stats?.pool ?? 0) + delta
  const wouldGoNegative = previewPool < 0

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!(amountNum > 0)) return setError(t('Enter an amount greater than zero.'))
    if (!reason.trim()) return setError(t('A reason is required for every pool edit.'))
    if (wouldGoNegative) {
      return setError(
        t('This would leave the pool negative ({amount}). Choose a smaller decrease.')
          .replace('{amount}', formatTZS(previewPool)),
      )
    }
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
      <div className="rounded-xl bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 text-sm space-y-1">
        <div className="flex justify-between">
          <span className="text-slate-500">{t('Current pool')}</span>
          <span className="text-slate-900 tabular-nums">{formatTZS(stats?.pool ?? 0)}</span>
        </div>
        <div className="flex justify-between">
          <span className="text-slate-500">{t('Current total assets')}</span>
          <span className="text-slate-900 tabular-nums">
            {formatTZS(stats?.totalAssets ?? stats?.pool ?? 0)}
          </span>
        </div>
      </div>

      <DirectionToggle direction={direction} onChange={setDirection} />

      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">{t('Amount (TSh)')}</label>
        <input
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
            {t('After approval: pool {pool} · total assets {total}.')
              .replace('{pool}', formatTZS(previewPool))
              .replace('{total}', formatTZS(previewTotal))}
          </p>
        )}
      </div>

      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">{t('Reason')}</label>
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={2}
          placeholder={t('e.g. recorded interest from external account, or correction of a deposit mis-entry')}
          className="input-field"
        />
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="rounded-xl bg-amber-50 ring-1 ring-inset ring-amber-200/70 p-3 text-xs text-amber-800">
        {t("Two other admins must approve this edit before it applies. You can't approve your own request.")}
      </div>

      <div className="flex gap-2">
        <button
          type="submit"
          disabled={busy}
          className="flex-1 inline-flex items-center justify-center min-h-11 rounded-xl bg-sky-600 text-white text-sm font-medium px-4 transition-all duration-150 hover:bg-sky-700 active:scale-[0.99] disabled:opacity-50 disabled:cursor-not-allowed shadow-[0_1px_2px_-1px_rgba(2,132,199,0.5)]"
        >
          {busy ? t('Submitting…') : t('Submit edit')}
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
    <Modal open={open} onClose={onClose} title={t('Edit group total assets')}>
      {open && <Form stats={stats} onSubmitted={onSubmitted} onClose={onClose} />}
    </Modal>
  )
}
