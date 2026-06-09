// Pending member-deletion requests. Same 2-of-N approval pattern as
// PaymentQueueItem/LoanQueueItem. The target (if they were an admin) cannot
// vote on their own deletion. Any admin can cancel a pending request.
import { useState } from 'react'
import { supabase } from '../../supabaseClient'
import { formatTZS, formatDate } from '../../lib/format'
import { approveMemberDeletion, cancelMemberDeletion } from '../../lib/admin'

function Row({ label, value, danger }) {
  return (
    <div className="flex justify-between text-sm">
      <span className="text-slate-500">{label}</span>
      <span
        className={`tabular-nums ${danger ? 'font-semibold text-red-700' : 'text-slate-900'}`}
      >
        {value}
      </span>
    </div>
  )
}

function DeletionItem({ request, onActioned }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const snap = request.target_snapshot || {}
  const name = snap.full_name || 'Unknown member'

  async function handleApprove() {
    setError('')
    setBusy(true)
    try {
      await approveMemberDeletion(supabase, request.id)
      onActioned?.()
    } catch (err) {
      setError(err?.message || 'Could not approve the deletion.')
    } finally {
      setBusy(false)
    }
  }

  async function handleCancel() {
    setError('')
    if (!window.confirm('Cancel this deletion request?')) return
    setBusy(true)
    try {
      await cancelMemberDeletion(supabase, request.id)
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
      ? `Approve & delete (${request.approvalsCount + 1}/${request.requiredApprovals})`
      : `Submit approval (${request.approvalsCount + 1}/${request.requiredApprovals})`

  let note = null
  if (request.isSelf) {
    note = "You can't approve your own deletion."
  } else if (request.iApproved) {
    note = `You've already approved (${request.approvalsCount}/${request.requiredApprovals}). Awaiting another admin.`
  } else if (request.approvalsCount > 0) {
    note = `Approved by ${request.approverNames.join(', ')} (${request.approvalsCount}/${request.requiredApprovals}).`
  }

  return (
    <div className="rounded-xl border border-red-200/80 bg-red-50/40 p-4 space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-medium text-slate-900">Delete {name}</p>
          <p className="text-xs text-slate-500 mt-0.5">
            Requested by {request.requesterName} ·{' '}
            {formatDate(request.created_at?.slice(0, 10))}
          </p>
        </div>
        {snap.role === 'admin' && (
          <span className="inline-flex items-center rounded-full bg-amber-50 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-amber-700 ring-1 ring-inset ring-amber-200">
            admin
          </span>
        )}
      </div>

      {note && (
        <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 ring-1 ring-inset ring-amber-200/70 text-amber-800">
          {note}
        </p>
      )}

      <div className="rounded-lg bg-white ring-1 ring-inset ring-slate-100 p-3 space-y-1">
        <Row label="Email" value={snap.email || '—'} />
        <Row label="Phone" value={snap.phone_number || '—'} />
        <Row
          label="Total savings (will be lost)"
          value={formatTZS(request.targetSavings)}
          danger
        />
        {request.reason && (
          <p className="text-xs text-slate-500 mt-2">
            <span className="font-medium text-slate-700">Reason:</span> {request.reason}
          </p>
        )}
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="flex gap-2">
        <button
          onClick={handleApprove}
          disabled={busy || !request.canApprove}
          className="btn-danger flex-1"
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

export default function DeletionRequestsQueue({ pendingDeletions, onActioned }) {
  if (!pendingDeletions || pendingDeletions.length === 0) return null

  return (
    <section className="rounded-2xl border border-red-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-red-700 mb-3">
        Pending member deletions ({pendingDeletions.length})
      </h2>
      <div className="space-y-3">
        {pendingDeletions.map((r) => (
          <DeletionItem key={r.id} request={r} onActioned={onActioned} />
        ))}
      </div>
    </section>
  )
}
