// Raise a loan on a member's behalf. Members no longer request loans — they ask
// an admin in person, and the admin files it here.
//
// This only creates the pending row. Disbursement is still approve_loan: 2-of-N,
// with the M-Pesa screenshot attached at the second signature, exactly as before.
//
// The ceiling shown here is advisory. approve_loan enforces both caps (a multiple
// of the member's contribution, and a fraction of the group pool) and file_loan
// enforces one-loan-at-a-time. Nothing here is a guard; it just saves the admin
// filing something that will be refused later.
import { useCallback, useEffect, useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { useLanguage } from '../../hooks/useLanguage'
import { fileLoan, maxLoanFor } from '../../lib/loans'
import { formatTZS } from '../../lib/format'

function Form({ members, onSubmitted, onClose }) {
  const { t } = useLanguage()
  const [memberId, setMemberId] = useState('')
  const [amount, setAmount] = useState('')
  const [limits, setLimits] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const loadLimits = useCallback(async () => {
    setLimits(null)
    if (!supabase || !memberId) return
    try {
      setLimits(await maxLoanFor(supabase, memberId))
    } catch {
      // Advisory only — a failure here must not stop the admin filing.
      setLimits(null)
    }
  }, [memberId])

  useEffect(() => {
    // load() sets a loading/reset flag synchronously before it awaits. That is
    // the one render the rule is warning about, and it is the intended one:
    // the panel must show its loading state the moment the input changes.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    loadLimits()
  }, [loadLimits])

  const over = limits && Number(amount) > limits.ceiling

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!memberId) return setError(t('Choose a member.'))
    if (!(Number(amount) > 0)) return setError(t('Enter an amount greater than zero.'))
    setBusy(true)
    try {
      await fileLoan(supabase, memberId, Number(amount))
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || t('Could not file the loan.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div>
        <label htmlFor="loan-member" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Member')}
        </label>
        <select
          id="loan-member"
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
            <span className="text-slate-500">{t('Their savings')}</span>
            <span className="tabular-nums text-slate-900">
              {formatTZS(limits.contribution.total)}
            </span>
          </div>
          <div className="flex justify-between">
            <span className="text-slate-500">{t('Max eligible')}</span>
            <span className="tabular-nums text-slate-900">{formatTZS(limits.ceiling)}</span>
          </div>
        </div>
      )}

      <div>
        <label htmlFor="loan-amount" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Loan amount (TSh)')}
        </label>
        <input
          id="loan-amount"
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
            {t('Above the {amount} ceiling — the database will refuse to approve it.').replace(
              '{amount}',
              formatTZS(limits.ceiling),
            )}
          </p>
        )}
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="rounded-xl bg-amber-50 ring-1 ring-inset ring-amber-200/70 p-3 text-xs text-amber-800">
        {t('This only raises the request. Two admins must approve it, and the M-Pesa proof is attached at approval.')}
      </div>

      <div className="flex gap-2">
        <button type="submit" disabled={busy} className="btn-primary flex-1">
          {busy ? t('Filing…') : t('File loan')}
        </button>
        <button type="button" onClick={onClose} className="btn-secondary">
          {t('Cancel')}
        </button>
      </div>
    </form>
  )
}

export default function FileLoanModal({ open, onClose, members = [], onSubmitted }) {
  const { t } = useLanguage()
  return (
    <Modal open={open} onClose={onClose} title={t('File a loan')}>
      {open && <Form members={members} onSubmitted={onSubmitted} onClose={onClose} />}
    </Modal>
  )
}
