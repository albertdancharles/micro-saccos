// Propose a change to one of the group's financial rules (admin-only, migration 020).
// The requester's vote does NOT auto-count; two OTHER admins must approve before the
// new rule takes effect — and it only ever applies to NEW fees and loans.
import { useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import {
  requestSettingChange,
  formatSettingValue,
  SETTING_KIND,
  SETTING_DEFAULTS,
} from '../../lib/settings'
import { useLanguage } from '../../hooks/useLanguage'

// Percent settings are stored as fractions (0.05) but entered as percentages (5),
// because nobody wants to type "0.05" for a five-percent penalty.
const toStored = (key, entered) =>
  SETTING_KIND[key] === 'percent' ? Number(entered) / 100 : Number(entered)
const toEntered = (key, stored) =>
  SETTING_KIND[key] === 'percent' ? Number((Number(stored) * 100).toFixed(4)) : Number(stored)

function Form({ rows, onSubmitted, onClose }) {
  const { t } = useLanguage()
  const [key, setKey] = useState(rows[0]?.key || 'monthly_fee_amount')
  const [value, setValue] = useState('')
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const row = rows.find((r) => r.key === key)
  const current = Number(row?.value ?? SETTING_DEFAULTS[key] ?? 0)
  const min = Number(row?.min_value ?? 0)
  const max = Number(row?.max_value ?? 0)
  const isPercent = SETTING_KIND[key] === 'percent'

  const entered = value === '' ? null : Number(value)
  const proposed = entered === null ? null : toStored(key, entered)
  const outOfRange = proposed !== null && (proposed < min || proposed > max)
  const unchanged = proposed !== null && proposed === current

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (proposed === null || Number.isNaN(proposed)) return setError(t('Enter a new value.'))
    if (unchanged) return setError(t('That is already the current value.'))
    if (outOfRange) {
      return setError(
        t('Must be between {min} and {max}.')
          .replace('{min}', formatSettingValue(key, min, formatTZS))
          .replace('{max}', formatSettingValue(key, max, formatTZS)),
      )
    }
    if (!reason.trim()) return setError(t('A reason is required for every rule change.'))

    setBusy(true)
    try {
      await requestSettingChange(supabase, key, proposed, reason.trim())
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || t('Could not open the rule change request.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div>
        <label htmlFor="setting-key" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Rule')}
        </label>
        <select
          id="setting-key"
          value={key}
          onChange={(e) => {
            setKey(e.target.value)
            setValue('')
            setError('')
          }}
          className="input-field"
        >
          {rows.map((r) => (
            <option key={r.key} value={r.key}>
              {t(r.label)}
            </option>
          ))}
        </select>
      </div>

      <div className="rounded-xl bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 text-sm space-y-1">
        <div className="flex justify-between">
          <span className="text-slate-500">{t('Current value')}</span>
          <span className="text-slate-900 tabular-nums">
            {formatSettingValue(key, current, formatTZS)}
          </span>
        </div>
        <div className="flex justify-between">
          <span className="text-slate-500">{t('Allowed range')}</span>
          <span className="text-slate-500 tabular-nums">
            {formatSettingValue(key, min, formatTZS)} – {formatSettingValue(key, max, formatTZS)}
          </span>
        </div>
      </div>

      <div>
        <label htmlFor="setting-value" className="block text-sm font-medium text-slate-700 mb-1">
          {isPercent ? t('New value (%)') : t('New value')}
        </label>
        <input
          id="setting-value"
          type="number"
          step="any"
          inputMode="decimal"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          placeholder={String(toEntered(key, current))}
          className="input-field tabular-nums"
        />
        {proposed !== null && !Number.isNaN(proposed) && (
          <p className={`mt-1 text-xs tabular-nums ${outOfRange ? 'text-red-600' : 'text-slate-500'}`}>
            {t('{label}: {from} → {to}')
              .replace('{label}', t(row?.label || key))
              .replace('{from}', formatSettingValue(key, current, formatTZS))
              .replace('{to}', formatSettingValue(key, proposed, formatTZS))}
          </p>
        )}
      </div>

      <div>
        <label htmlFor="setting-reason" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Reason')}
        </label>
        <textarea
          id="setting-reason"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={2}
          placeholder={t('e.g. agreed at the January meeting to raise the monthly fee')}
          className="input-field"
        />
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="rounded-xl bg-amber-50 ring-1 ring-inset ring-amber-200/70 p-3 text-xs text-amber-800 space-y-1">
        <p>
          {t("Two other admins must approve this change before it applies. You can't approve your own request.")}
        </p>
        <p>
          {t('New rules apply to future fees and loans only — penalties and interest already charged never change.')}
        </p>
      </div>

      <div className="flex gap-2">
        <button type="submit" disabled={busy} className="btn-info flex-1">
          {busy ? t('Submitting…') : t('Propose change')}
        </button>
        <button type="button" onClick={onClose} className="btn-secondary">
          {t('Cancel')}
        </button>
      </div>
    </form>
  )
}

export default function RequestSettingChangeModal({ open, onClose, rows, onSubmitted }) {
  const { t } = useLanguage()
  return (
    <Modal open={open} onClose={onClose} title={t('Change a group rule')}>
      {open && rows?.length > 0 && (
        <Form rows={rows} onSubmitted={onSubmitted} onClose={onClose} />
      )}
    </Modal>
  )
}
