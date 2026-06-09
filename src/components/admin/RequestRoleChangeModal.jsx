// Open a role-change request (promote a member to admin, or revoke an admin).
// Same 2-of-N pattern as savings/pool edits: the requester does NOT auto-vote,
// and two OTHER admins must approve.
import { useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { requestRoleChange } from '../../lib/admin'

function Form({ target, onSubmitted, onClose }) {
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const isPromote = target.role !== 'admin'
  const changeType = isPromote ? 'promote' : 'demote'
  const verb = isPromote ? 'Promote to admin' : 'Revoke admin role'
  const danger = !isPromote

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!reason.trim()) return setError('A reason is required for every role change.')
    setBusy(true)
    try {
      await requestRoleChange(supabase, target.id, changeType, reason.trim())
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || 'Could not open the role-change request.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div
        className={`rounded-xl ring-1 ring-inset p-3 text-sm space-y-1 ${
          danger
            ? 'bg-red-50 ring-red-200 text-red-800'
            : 'bg-emerald-50 ring-emerald-200 text-emerald-800'
        }`}
      >
        <p className="font-semibold">{verb}</p>
        <p>
          <strong>{target.name}</strong> is currently{' '}
          <span className="font-mono">{target.role}</span>.
          {isPromote
            ? ' Becoming an admin lets them approve transactions and request edits.'
            : ' Revoking admin removes their ability to approve and request edits.'}
        </p>
      </div>

      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">Reason</label>
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={2}
          placeholder={
            isPromote
              ? 'e.g. trusted treasurer, served as group secretary'
              : 'e.g. stepping down, no longer active in committee'
          }
          className="input-field"
        />
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="rounded-xl bg-amber-50 ring-1 ring-inset ring-amber-200/70 p-3 text-xs text-amber-800">
        Two <strong>other</strong> admins must approve before the role flips. You can't
        approve your own request.
      </div>

      <div className="flex gap-2">
        <button
          type="submit"
          disabled={busy}
          className={`${danger ? 'btn-danger' : 'btn-primary'} flex-1`}
        >
          {busy ? 'Submitting…' : `Request ${isPromote ? 'promotion' : 'revocation'}`}
        </button>
        <button type="button" onClick={onClose} className="btn-secondary">
          Cancel
        </button>
      </div>
    </form>
  )
}

export default function RequestRoleChangeModal({ open, onClose, target, onSubmitted }) {
  const title = target?.role === 'admin' ? 'Revoke admin role' : 'Promote to admin'
  return (
    <Modal open={open} onClose={onClose} title={title}>
      {open && target && <Form target={target} onSubmitted={onSubmitted} onClose={onClose} />}
    </Modal>
  )
}
