// Pending admin role-change requests. Same 2-of-N pattern as savings/pool
// edits: requester does NOT auto-vote, target can't approve, any admin can
// cancel a pending request.
import { useState } from 'react'
import { supabase } from '../../supabaseClient'
import { formatDate } from '../../lib/format'
import { approveRoleChange, cancelRoleChange } from '../../lib/admin'

function ChangeItem({ request, onActioned }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const isPromote = request.change_type === 'promote'
  const verb = isPromote ? 'Promote' : 'Revoke admin from'

  async function handleApprove() {
    setError('')
    setBusy(true)
    try {
      await approveRoleChange(supabase, request.id)
      onActioned?.()
    } catch (err) {
      setError(err?.message || 'Could not approve the role change.')
    } finally {
      setBusy(false)
    }
  }

  async function handleCancel() {
    setError('')
    if (!window.confirm('Cancel this role-change request?')) return
    setBusy(true)
    try {
      await cancelRoleChange(supabase, request.id)
      onActioned?.()
    } catch (err) {
      setError(err?.message || 'Could not cancel.')
    } finally {
      setBusy(false)
    }
  }

  const willFinalize = request.approvalsCount + 1 >= request.requiredApprovals
  const approveLabel = busy
    ? 'Working…'
    : willFinalize
      ? `Approve & apply (${request.approvalsCount + 1}/${request.requiredApprovals})`
      : `Submit approval (${request.approvalsCount + 1}/${request.requiredApprovals})`

  let note = null
  if (request.isRequester) {
    note = "You opened this request — you can't vote on it. Awaiting other admins."
  } else if (request.isTarget) {
    note = "This change targets you — you can't approve it."
  } else if (request.iApproved) {
    note = `You've already approved (${request.approvalsCount}/${request.requiredApprovals}). Awaiting another admin.`
  } else if (request.approvalsCount > 0) {
    note = `Approved by ${request.approverNames.join(', ')} (${request.approvalsCount}/${request.requiredApprovals}).`
  }

  return (
    <div className={`rounded-xl border p-4 space-y-3 ${
      isPromote ? 'border-emerald-200 bg-emerald-50/30' : 'border-red-200 bg-red-50/30'
    }`}>
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-medium text-gray-900">
            {verb} {request.targetName}
          </p>
          <p className="text-xs text-gray-500">
            Requested by {request.requesterName} · {formatDate(request.created_at?.slice(0, 10))}
          </p>
        </div>
        <span
          className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${
            isPromote ? 'bg-emerald-100 text-emerald-700' : 'bg-red-100 text-red-700'
          }`}
        >
          {isPromote ? 'promote' : 'revoke'}
        </span>
      </div>

      {note && (
        <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 border border-amber-100 text-amber-800">
          {note}
        </p>
      )}

      {request.reason && (
        <div className="rounded-lg bg-white border border-gray-100 p-3">
          <p className="text-xs text-gray-500">
            <span className="font-medium text-gray-700">Reason:</span> {request.reason}
          </p>
        </div>
      )}

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="flex gap-2">
        <button
          onClick={handleApprove}
          disabled={busy || !request.canApprove}
          className={`flex-1 rounded-lg text-white text-sm font-medium py-2 disabled:opacity-50 disabled:cursor-not-allowed ${
            isPromote ? 'bg-emerald-600' : 'bg-red-600'
          }`}
        >
          {approveLabel}
        </button>
        <button
          onClick={handleCancel}
          disabled={busy}
          className="rounded-lg border border-gray-300 text-sm px-4 py-2 text-gray-600"
        >
          Cancel request
        </button>
      </div>
    </div>
  )
}

export default function RoleChangeQueue({ pendingRoleChanges, onActioned }) {
  if (!pendingRoleChanges || pendingRoleChanges.length === 0) return null

  return (
    <section className="rounded-2xl border border-gray-200 bg-white p-4">
      <h2 className="text-sm font-semibold text-gray-900 mb-3">
        Pending role changes ({pendingRoleChanges.length})
      </h2>
      <div className="space-y-3">
        {pendingRoleChanges.map((r) => (
          <ChangeItem key={r.id} request={r} onActioned={onActioned} />
        ))}
      </div>
    </section>
  )
}
