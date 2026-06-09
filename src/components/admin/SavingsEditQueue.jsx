// Pending savings-edit requests. 2-of-N approval pattern, but stricter than
// the rest of the system: the requester does NOT auto-vote, and neither the
// requester nor the target can approve. Any admin can cancel a pending request.
import { useState } from 'react'
import { supabase } from '../../supabaseClient'
import { formatTZS, formatDate } from '../../lib/format'
import { approveSavingsEdit, cancelSavingsEdit } from '../../lib/admin'

function Row({ label, value, danger, accent }) {
  return (
    <div className="flex justify-between text-sm">
      <span className="text-slate-500">{label}</span>
      <span
        className={`tabular-nums ${
          danger
            ? 'font-semibold text-red-700'
            : accent
              ? 'font-semibold text-emerald-700'
              : 'text-slate-900'
        }`}
      >
        {value}
      </span>
    </div>
  )
}

function EditItem({ request, onActioned }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const delta = Number(request.delta)
  const projected = Number(request.currentSavings) + delta

  async function handleApprove() {
    setError('')
    setBusy(true)
    try {
      await approveSavingsEdit(supabase, request.id)
      onActioned?.()
    } catch (err) {
      setError(err?.message || 'Could not approve the edit.')
    } finally {
      setBusy(false)
    }
  }

  async function handleCancel() {
    setError('')
    if (!window.confirm('Cancel this savings edit request?')) return
    setBusy(true)
    try {
      await cancelSavingsEdit(supabase, request.id)
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
    note = "This edit targets your own savings — you can't approve it."
  } else if (request.iApproved) {
    note = `You've already approved (${request.approvalsCount}/${request.requiredApprovals}). Awaiting another admin.`
  } else if (request.approvalsCount > 0) {
    note = `Approved by ${request.approverNames.join(', ')} (${request.approvalsCount}/${request.requiredApprovals}).`
  }

  return (
    <div className="rounded-xl border border-slate-200/80 bg-white p-4 space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-medium text-slate-900">Edit {request.targetName}'s savings</p>
          <p className="text-xs text-slate-500 mt-0.5">
            Requested by {request.requesterName} ·{' '}
            {formatDate(request.created_at?.slice(0, 10))}
          </p>
        </div>
        <p
          className={`text-lg font-semibold tabular-nums ${
            delta >= 0 ? 'text-emerald-700' : 'text-red-700'
          }`}
        >
          {delta >= 0 ? '+' : ''}
          {formatTZS(delta)}
        </p>
      </div>

      {note && (
        <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 ring-1 ring-inset ring-amber-200/70 text-amber-800">
          {note}
        </p>
      )}

      <div className="rounded-lg bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 space-y-1">
        <Row label="Current savings" value={formatTZS(request.currentSavings)} />
        <Row
          label="After edit"
          value={formatTZS(projected)}
          danger={projected < 0}
          accent={delta > 0}
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
          className="btn-primary flex-1"
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

export default function SavingsEditQueue({ pendingSavingsEdits, onActioned }) {
  if (!pendingSavingsEdits || pendingSavingsEdits.length === 0) return null

  return (
    <section className="rounded-2xl border border-emerald-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-emerald-700 mb-3">
        Pending savings edits ({pendingSavingsEdits.length})
      </h2>
      <div className="space-y-3">
        {pendingSavingsEdits.map((r) => (
          <EditItem key={r.id} request={r} onActioned={onActioned} />
        ))}
      </div>
    </section>
  )
}
