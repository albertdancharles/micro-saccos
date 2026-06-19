// Open a deletion request for a member. Shows a stark summary of what will be
// wiped (savings, paid fees, loans) so the admin understands the consequence,
// requires a reason, and calls request_member_deletion. The second admin must
// then approve from the queue.
import { useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { requestMemberDeletion } from '../../lib/admin'
import { useLanguage } from '../../hooks/useLanguage'

function Form({ target, onSubmitted, onClose }) {
  const { t } = useLanguage()
  const [reason, setReason] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const phrase = (target?.name || '').trim().toUpperCase()
  const ready = !!phrase && confirm.trim().toUpperCase() === phrase

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!reason.trim())
      return setError(t('Add a short reason — every deletion is recorded in the audit log.'))
    if (!ready) return setError(t('Type {NAME} exactly to confirm.').replace('{NAME}', target.name.toUpperCase()))
    setBusy(true)
    try {
      await requestMemberDeletion(supabase, target.id, reason.trim())
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || t('Could not open the deletion request.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div className="rounded-xl bg-red-50 ring-1 ring-inset ring-red-200 p-3 text-sm text-red-700 space-y-1">
        <p className="font-semibold">{t('This is irreversible.')}</p>
        <p>
          {t('Once two admins authorize, {name} and every record below will be permanently deleted. The group pool decreases by their approved savings.')
            .replace('{name}', target.name)}
        </p>
      </div>

      <div className="rounded-xl bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 text-sm space-y-1">
        <div className="flex justify-between">
          <span className="text-slate-500">{t('Total savings')}</span>
          <span className="text-slate-900 tabular-nums">{formatTZS(target.savings)}</span>
        </div>
        <p className="text-xs text-slate-500">
          {t('Includes deposits, paid monthly fees, and admin adjustments. All erased.')}
        </p>
        {target.hasActiveLoan && (
          <p className="text-xs text-red-600 mt-1">
            {t('This member has an active loan. Deleting them will wipe the loan and its repayment history — the pool loses the outstanding principal.')}
          </p>
        )}
        {target.role === 'admin' && (
          <p className="text-xs text-amber-700 mt-1">
            {t('This member is an admin. The system blocks deleting the last remaining admin.')}
          </p>
        )}
      </div>

      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">{t('Reason')}</label>
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={2}
          placeholder={t('e.g. member exited the group')}
          className="input-field"
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">
          {t('Type')}{' '}
          <span className="font-mono text-red-700">{target.name.toUpperCase()}</span>{' '}
          {t('to confirm')}
        </label>
        <input
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
          className="input-field"
        />
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="flex gap-2">
        <button type="submit" disabled={busy || !ready} className="btn-danger flex-1">
          {busy ? t('Submitting…') : t('Request deletion')}
        </button>
        <button type="button" onClick={onClose} className="btn-secondary">
          {t('Cancel')}
        </button>
      </div>
    </form>
  )
}

export default function RequestDeletionModal({ open, onClose, target, onSubmitted }) {
  const { t } = useLanguage()
  return (
    <Modal open={open} onClose={onClose} title={t('Request member deletion')}>
      {open && target && <Form target={target} onSubmitted={onSubmitted} onClose={onClose} />}
    </Modal>
  )
}
