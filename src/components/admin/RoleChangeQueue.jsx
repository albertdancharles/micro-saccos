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
    <div
      className={`rounded-xl border p-4 space-y-3 ${
        isPromote
          ? 'border-emerald-200/80 bg-emerald-50/40'
          : 'border-red-200/80 bg-red-50/40'
      }`}
    >
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-medium text-slate-900">
            {verb} {request.targetName}
          </p>
          <p className="text-xs text-slate-500 mt-0.5">
            Requested by {request.requesterName} ·{' '}
            {formatDate(request.created_at?.slice(0, 10))}
          </p>
        </div>
        <span
          className={`inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide ring-1 ring-inset ${
            isPromote
              ? 'bg-emerald-50 text-emerald-700 ring-emerald-200'
              : 'bg-red-50 text-red-700 ring-red-200'
          }`}
        >
          {isPromote ? 'promote' : 'revoke'}
        </span>
      </div>

      {note && (
        <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 ring-1 ring-inset ring-amber-200/70 text-amber-800">
          {note}
        </p>
      )}

      {request.reason && (
        <div className="rounded-lg bg-white ring-1 ring-inset ring-slate-100 p-3">
          <p className="text-xs text-slate-500">
            <span className="font-medium text-slate-700">Reason:</span> {request.reason}
          </p>
        </div>
      )}

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="flex gap-2">
        <button
          onClick={handleApprove}
          disabled={busy || !request.canApprove}
          className={`${isPromote ? 'btn-primary' : 'btn-danger'} flex-1`}
        >
          {approveLabel}
        </button>
        <button onClick={handleCancel} disabled={busy} className="btn-secondary">
          Cancel request
        </button>
      </div>
    </div>
  )
}

export default function RoleChangeQueue({ pendingRoleChanges, onActioned }) {
  if (!pendingRoleChanges || pendingRoleChanges.length === 0) return null

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-3">
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
