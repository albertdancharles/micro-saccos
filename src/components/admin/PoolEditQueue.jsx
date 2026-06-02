// Pending pool-edit requests. 2-of-N approval. Requester does NOT auto-vote
// and cannot approve their own request.
import { useState } from 'react'
import { supabase } from '../../supabaseClient'
import { formatTZS, formatDate } from '../../lib/format'
import { approvePoolEdit, cancelPoolEdit } from '../../lib/admin'

function Row({ label, value, danger, accent }) {
  return (
    <div className="flex justify-between text-sm">
      <span className="text-gray-500">{label}</span>
      <span
        className={
          danger
            ? 'font-medium text-red-700'
            : accent
              ? 'font-medium text-sky-700'
              : 'text-gray-900'
        }
      >
        {value}
      </span>
    </div>
  )
}

function EditItem({ request, stats, onActioned }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const delta = Number(request.delta)
  const currentPool = Number(stats?.pool ?? 0)
  const currentTotal = Number(stats?.totalAssets ?? currentPool)
  const projectedPool = currentPool + delta
  const projectedTotal = currentTotal + delta

  async function handleApprove() {
    setError('')
    setBusy(true)
    try {
      await approvePoolEdit(supabase, request.id)
      onActioned?.()
    } catch (err) {
      setError(err?.message || 'Could not approve the edit.')
    } finally {
      setBusy(false)
    }
  }

  async function handleCancel() {
    setError('')
    if (!window.confirm('Cancel this pool edit request?')) return
    setBusy(true)
    try {
      await cancelPoolEdit(supabase, request.id)
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
  } else if (request.iApproved) {
    note = `You've already approved (${request.approvalsCount}/${request.requiredApprovals}). Awaiting another admin.`
  } else if (request.approvalsCount > 0) {
    note = `Approved by ${request.approverNames.join(', ')} (${request.approvalsCount}/${request.requiredApprovals}).`
  }

  return (
    <div className="rounded-xl border border-gray-200 p-4 space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-medium text-gray-900">Adjust group pool</p>
          <p className="text-xs text-gray-500">
            Requested by {request.requesterName} · {formatDate(request.created_at?.slice(0, 10))}
          </p>
        </div>
        <p
          className={`text-lg font-semibold ${delta >= 0 ? 'text-emerald-700' : 'text-red-700'}`}
        >
          {delta >= 0 ? '+' : ''}
          {formatTZS(delta)}
        </p>
      </div>

      {note && (
        <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 border border-amber-100 text-amber-800">
          {note}
        </p>
      )}

      <div className="rounded-lg bg-gray-50 p-3 space-y-1">
        <Row label="Current pool" value={formatTZS(currentPool)} />
        <Row
          label="After edit · pool"
          value={formatTZS(projectedPool)}
          danger={projectedPool < 0}
          accent={delta > 0}
        />
        <Row label="Current total assets" value={formatTZS(currentTotal)} />
        <Row
          label="After edit · total assets"
          value={formatTZS(projectedTotal)}
          accent={delta > 0}
        />
        {request.reason && (
          <p className="text-xs text-gray-500 mt-2">
            <span className="font-medium text-gray-700">Reason:</span> {request.reason}
          </p>
        )}
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="flex gap-2">
        <button
          onClick={handleApprove}
          disabled={busy || !request.canApprove}
          className="flex-1 rounded-lg bg-sky-600 text-white text-sm font-medium py-2 disabled:opacity-50 disabled:cursor-not-allowed"
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

export default function PoolEditQueue({ pendingPoolEdits, stats, onActioned }) {
  if (!pendingPoolEdits || pendingPoolEdits.length === 0) return null

  return (
    <section className="rounded-2xl border border-sky-200 bg-white p-4">
      <h2 className="text-sm font-semibold text-sky-700 mb-3">
        Pending total-assets edits ({pendingPoolEdits.length})
      </h2>
      <div className="space-y-3">
        {pendingPoolEdits.map((r) => (
          <EditItem key={r.id} request={r} stats={stats} onActioned={onActioned} />
        ))}
      </div>
    </section>
  )
}
