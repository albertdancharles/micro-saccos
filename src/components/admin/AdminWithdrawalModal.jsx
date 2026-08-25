// Open a withdrawal on a member's behalf. Members used to raise these themselves;
// since the admin mandate they ask off-app and an admin files it here.
//
// Nothing downstream changed: 2-of-N still authorises it, and the member's savings
// only move when an admin records the actual payout with a proof.
//
// The ceiling is real and worth showing: a borrower cannot withdraw the savings
// securing their own loan, so `withdrawable` is usually less than `savings`.
import { useCallback, useEffect, useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { useLanguage } from '../../hooks/useLanguage'
import { adminRequestWithdrawal, getWithdrawable } from '../../lib/withdrawals'
import { formatTZS } from '../../lib/format'

function Form({ members, onSubmitted, onClose }) {
  const { t } = useLanguage()
  const [memberId, setMemberId] = useState('')
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  const [limits, setLimits] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    setLimits(null)
    if (!supabase || !memberId) return
    try {
      setLimits(await getWithdrawable(supabase, memberId))
    } catch {
      setLimits(null)
    }
  }, [memberId])

  useEffect(() => {
    // load() sets a loading/reset flag synchronously before it awaits. That is
    // the one render the rule is warning about, and it is the intended one:
    // the panel must show its loading state the moment the input changes.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  const max = Number(limits?.withdrawable_tzs ?? 0)
  const over = limits && Number(amount) > max

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!memberId) return setError(t('Choose a member.'))
    if (!(Number(amount) > 0)) return setError(t('Enter an amount greater than zero.'))
    if (!reason.trim()) return setError(t('A reason is required for every withdrawal.'))
    setBusy(true)
    try {
      await adminRequestWithdrawal(supabase, memberId, Number(amount), reason.trim())
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || t('Could not open the withdrawal.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div>
        <label htmlFor="wd-member" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Member')}
        </label>
        <select
          id="wd-member"
          value={memberId}
          onChange={(e) => setMemberId(e.target.value)}
          className="input-field"
        >
          <option value="">{t('Choose a member…')}</option>
          {members.map((m) => (
            <option key={m.id} value={m.id}>
              {m.full_name}
            </option>
          ))}
        </select>
      </div>

      {limits && (
        <div className="rounded-xl bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 text-sm space-y-1">
          <div className="flex justify-between">
            <span className="text-slate-500">{t('Savings')}</span>
            <span className="tabular-nums text-slate-900">{formatTZS(limits.savings_tzs)}</span>
          </div>
          {Number(limits.locked_tzs) > 0 && (
            <div className="flex justify-between">
              <span className="text-slate-500">{t('Locked behind their loan')}</span>
              <span className="tabular-nums text-amber-700">
                −{formatTZS(limits.locked_tzs)}
              </span>
            </div>
          )}
          <div className="flex justify-between border-t border-slate-200 pt-1">
            <span className="text-slate-500">{t('Can withdraw')}</span>
            <span className="tabular-nums font-medium text-slate-900">{formatTZS(max)}</span>
          </div>
        </div>
      )}

      <div>
        <label htmlFor="wd-amount" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Amount (TSh)')}
        </label>
        <input
          id="wd-amount"
          type="number"
          min="0"
          inputMode="numeric"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          placeholder="0"
          className="input-field tabular-nums"
        />
        {over && (
          <p className="mt-1 text-xs text-red-600">
            {t('They can withdraw at most {amount} right now.').replace('{amount}', formatTZS(max))}
          </p>
        )}
      </div>

      <div>
        <label htmlFor="wd-reason" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Reason')}
        </label>
        <textarea
          id="wd-reason"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={2}
          placeholder={t('e.g. school fees')}
          className="input-field"
        />
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="rounded-xl bg-amber-50 ring-1 ring-inset ring-amber-200/70 p-3 text-xs text-amber-800">
        {t('Two admins must approve this, and the savings only move when the payout proof is recorded.')}
      </div>

      <div className="flex gap-2">
        <button type="submit" disabled={busy} className="btn-primary flex-1">
          {busy ? t('Opening…') : t('Open withdrawal')}
        </button>
        <button type="button" onClick={onClose} className="btn-secondary">
          {t('Cancel')}
        </button>
      </div>
    </form>
  )
}

export default function AdminWithdrawalModal({ open, onClose, members = [], onSubmitted }) {
  const { t } = useLanguage()
  return (
    <Modal open={open} onClose={onClose} title={t('Open a withdrawal')}>
      {open && <Form members={members} onSubmitted={onSubmitted} onClose={onClose} />}
    </Modal>
  )
}
