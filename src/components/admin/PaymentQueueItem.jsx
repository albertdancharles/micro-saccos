// Pending payment row (build plan §9, Decision #11). Multi-admin aware:
//   * 0 approvals → this admin is the first; editable amount input.
//   * 1+ approvals → the first amount wins; second admin confirms without editing.
//   * Self-submissions can never be approved by the same person.
import { useState } from 'react'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { getSignedUrl } from '../../lib/storage'
import { approveSubmission, rejectSubmission } from '../../lib/payments'

const TYPE_LABEL = {
  savings_deposit: 'Savings deposit',
  monthly_fee: 'Monthly fee',
  loan_installment: 'Loan repayment',
}

export default function PaymentQueueItem({ submission, onActioned }) {
  const firstAmount = submission.firstAmount
  const hasPriorApproval = submission.approvalsCount > 0
  const lockedAmount = hasPriorApproval ? Number(firstAmount) : null

  const [amount, setAmount] = useState(
    hasPriorApproval ? String(firstAmount) : String(submission.suggested),
  )
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [proofUrl, setProofUrl] = useState(null)
  const [loadingProof, setLoadingProof] = useState(false)
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')

  async function viewProof() {
    setError('')
    setLoadingProof(true)
    try {
      setProofUrl(await getSignedUrl(supabase, submission.proof_url))
    } catch (err) {
      setError(err?.message || 'Could not load the screenshot.')
    } finally {
      setLoadingProof(false)
    }
  }

  async function handleApprove() {
    setError('')
    // Second admin always sends the first approver's amount — locked above.
    const amt = hasPriorApproval ? lockedAmount : Number(amount)
    if (!(amt >= 0)) return setError('Enter the amount received.')
    setBusy(true)
    try {
      await approveSubmission(supabase, submission.id, amt)
      onActioned?.()
    } catch (err) {
      setError(err?.message || 'Could not approve the payment.')
    } finally {
      setBusy(false)
    }
  }

  async function handleReject() {
    setError('')
    if (!reason.trim()) return setError('Add a short reason for the rejection.')
    setBusy(true)
    try {
      await rejectSubmission(supabase, submission.id, reason.trim())
      onActioned?.()
    } catch (err) {
      setError(err?.message || 'Could not reject the payment.')
    } finally {
      setBusy(false)
    }
  }

  const willFinalize = submission.approvalsCount + 1 >= submission.requiredApprovals
  const approveLabel = busy
    ? 'Approving…'
    : willFinalize
      ? `Approve (${submission.approvalsCount + 1}/${submission.requiredApprovals})`
      : `Submit approval (${submission.approvalsCount + 1}/${submission.requiredApprovals})`

  let approvalNote = null
  if (submission.isSelf) {
    approvalNote = 'You can\'t approve your own submission.'
  } else if (submission.iApproved) {
    approvalNote = `You've already approved (${submission.approvalsCount}/${submission.requiredApprovals}). Awaiting another admin.`
  } else if (hasPriorApproval) {
    approvalNote = `Approved by ${submission.approverNames.join(', ')} (${submission.approvalsCount}/${submission.requiredApprovals}).`
  }

  return (
    <div className="rounded-xl border border-gray-200 p-4 space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-medium text-gray-900">{submission.memberName}</p>
          <p className="text-xs text-gray-400">{TYPE_LABEL[submission.submission_type]}</p>
        </div>
        <div className="text-right">
          <p className="text-sm text-gray-500">Claimed</p>
          <p className="font-semibold text-gray-900">{formatTZS(submission.amount_claimed)}</p>
          {submission.penalty > 0 && (
            <p className="text-xs text-red-600">incl. {formatTZS(submission.penalty)} penalty</p>
          )}
        </div>
      </div>

      {approvalNote && (
        <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 border border-amber-100 text-amber-800">
          {approvalNote}
        </p>
      )}

      {proofUrl ? (
        <a href={proofUrl} target="_blank" rel="noreferrer">
          <img src={proofUrl} alt="Payment proof" className="max-h-48 rounded-lg border border-gray-100" />
        </a>
      ) : (
        <button
          onClick={viewProof}
          disabled={loadingProof}
          className="text-sm text-emerald-600 hover:text-emerald-700 disabled:opacity-50"
        >
          {loadingProof ? 'Loading…' : 'View screenshot'}
        </button>
      )}

      {rejecting ? (
        <div className="space-y-2">
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={2}
            placeholder="Reason for rejection"
            className="w-full rounded-lg border border-gray-300 px-3 py-2 text-sm outline-none focus:border-emerald-500"
          />
          {error && <p className="text-sm text-red-600">{error}</p>}
          <div className="flex gap-2">
            <button
              onClick={handleReject}
              disabled={busy}
              className="flex-1 rounded-lg bg-red-600 text-white text-sm font-medium py-2 disabled:opacity-50"
            >
              {busy ? 'Rejecting…' : 'Confirm reject'}
            </button>
            <button
              onClick={() => { setRejecting(false); setError('') }}
              className="flex-1 rounded-lg border border-gray-300 text-sm py-2"
            >
              Cancel
            </button>
          </div>
        </div>
      ) : (
        <div className="space-y-2">
          <label className="block text-sm font-medium text-gray-700">Amount received (TSh)</label>
          {hasPriorApproval ? (
            <p className="rounded-lg border border-gray-200 bg-gray-50 px-3 py-2 text-gray-900">
              {formatTZS(lockedAmount)}{' '}
              <span className="text-xs text-gray-400">(locked by first approver)</span>
            </p>
          ) : (
            <input
              type="number"
              min="0"
              inputMode="numeric"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              disabled={!submission.canApprove}
              className="w-full rounded-lg border border-gray-300 px-3 py-2 text-gray-900 outline-none focus:border-emerald-500 focus:ring-2 focus:ring-emerald-200 disabled:bg-gray-50 disabled:text-gray-400"
            />
          )}
          {error && <p className="text-sm text-red-600">{error}</p>}
          <div className="flex gap-2">
            <button
              onClick={handleApprove}
              disabled={busy || !submission.canApprove}
              className="flex-1 rounded-lg bg-emerald-600 text-white text-sm font-medium py-2 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {approveLabel}
            </button>
            <button
              onClick={() => setRejecting(true)}
              className="rounded-lg border border-gray-300 text-sm px-4 py-2 text-gray-600"
            >
              Reject
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
