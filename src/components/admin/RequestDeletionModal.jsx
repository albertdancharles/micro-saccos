// Open a deletion request for a member. Shows a stark summary of what will be
// wiped (savings, paid fees, loans) so the admin understands the consequence,
// requires a reason, and calls request_member_deletion. The second admin must
// then approve from the queue.
import { useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { requestMemberDeletion } from '../../lib/admin'

function Form({ target, onSubmitted, onClose }) {
  const [reason, setReason] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const phrase = (target?.name || '').trim().toUpperCase()
  const ready = !!phrase && confirm.trim().toUpperCase() === phrase

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!reason.trim()) return setError('Add a short reason — every deletion is recorded in the audit log.')
    if (!ready) return setError(`Type ${target.name.toUpperCase()} exactly to confirm.`)
    setBusy(true)
    try {
      await requestMemberDeletion(supabase, target.id, reason.trim())
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || 'Could not open the deletion request.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700 space-y-1">
        <p className="font-semibold">This is irreversible.</p>
        <p>
          Once two admins authorize, <strong>{target.name}</strong> and every record below will
          be permanently deleted. The group pool decreases by their approved savings.
        </p>
      </div>

      <div className="rounded-lg bg-gray-50 p-3 text-sm space-y-1">
        <div className="flex justify-between">
          <span className="text-gray-500">Approved savings</span>
          <span className="text-gray-900">{formatTZS(target.savings)}</span>
        </div>
        <div className="flex justify-between">
          <span className="text-gray-500">Paid monthly fees</span>
          <span className="text-gray-900">{formatTZS(target.paidFees)}</span>
        </div>
        {target.hasActiveLoan && (
          <p className="text-xs text-red-600 mt-1">
            ⚠ This member has an active loan. Deleting them will wipe the loan and its repayment
            history — the pool loses the outstanding principal.
          </p>
        )}
        {target.role === 'admin' && (
          <p className="text-xs text-amber-700 mt-1">
            This member is an admin. The system blocks deleting the last remaining admin.
          </p>
        )}
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 mb-1">Reason</label>
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={2}
          placeholder="e.g. member exited the group"
          className="w-full rounded-lg border border-gray-300 px-3 py-2 text-sm outline-none focus:border-emerald-500"
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 mb-1">
          Type <span className="font-mono">{target.name.toUpperCase()}</span> to confirm
        </label>
        <input
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
          className="w-full rounded-lg border border-gray-300 px-3 py-2 text-gray-900 outline-none focus:border-red-500 focus:ring-2 focus:ring-red-200"
        />
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="flex gap-2">
        <button
          type="submit"
          disabled={busy || !ready}
          className="flex-1 rounded-lg bg-red-600 text-white font-medium py-2.5 hover:bg-red-700 disabled:opacity-50"
        >
          {busy ? 'Submitting…' : 'Request deletion'}
        </button>
        <button
          type="button"
          onClick={onClose}
          className="rounded-lg border border-gray-300 px-4 py-2.5 text-gray-600"
        >
          Cancel
        </button>
      </div>
    </form>
  )
}

export default function RequestDeletionModal({ open, onClose, target, onSubmitted }) {
  return (
    <Modal open={open} onClose={onClose} title="Request member deletion">
      {open && target && <Form target={target} onSubmitted={onSubmitted} onClose={onClose} />}
    </Modal>
  )
}
