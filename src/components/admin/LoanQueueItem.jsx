// Pending loan row (build plan §9). Multi-admin aware:
//   * 0 approvals → this admin is the first; uploads disbursement proof and submits.
//   * 1+ approvals → first proof wins; second admin views it and confirms (no upload).
//   * Self-loans can never be approved by the same person.
import { useState } from 'react'
import UploadZone from '../ui/UploadZone'
import { supabase } from '../../supabaseClient'
import { formatTZS, formatDate } from '../../lib/format'
import { approveLoan, rejectLoan } from '../../lib/loans'
import { buildDisbursementPath, uploadPaymentProof, getSignedUrl } from '../../lib/storage'

function Row({ label, value, danger }) {
  return (
    <div className="flex justify-between">
      <span className="text-gray-500">{label}</span>
      <span className={danger ? 'font-medium text-red-600' : 'text-gray-700'}>{value}</span>
    </div>
  )
}

export default function LoanQueueItem({ loan, onActioned }) {
  const hasPriorApproval = loan.approvalsCount > 0
  const [file, setFile] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  const [proofUrl, setProofUrl] = useState(null)
  const [loadingProof, setLoadingProof] = useState(false)

  const overLimit = Number(loan.principal) > Number(loan.maxEligible)
  const contribBinds = Number(loan.contributionCeiling) <= Number(loan.poolCeiling)

  async function viewProof() {
    setError('')
    setLoadingProof(true)
    try {
      setProofUrl(await getSignedUrl(supabase, loan.firstProofUrl))
    } catch (err) {
      setError(err?.message || 'Could not load the proof.')
    } finally {
      setLoadingProof(false)
    }
  }

  async function handleApprove() {
    setError('')
    setBusy(true)
    try {
      if (hasPriorApproval) {
        // Second admin: confirm using the first approver's proof URL (no upload).
        await approveLoan(supabase, loan.id, loan.firstProofUrl)
      } else {
        if (!file) {
          setError('Upload the M-Pesa disbursement screenshot first.')
          setBusy(false)
          return
        }
        const path = buildDisbursementPath(loan.id, file)
        await uploadPaymentProof(supabase, file, path)
        await approveLoan(supabase, loan.id, path)
      }
      onActioned?.()
    } catch (err) {
      setError(err?.message || 'Could not approve the loan.')
    } finally {
      setBusy(false)
    }
  }

  async function handleReject() {
    setError('')
    if (!reason.trim()) return setError('Add a short reason for the rejection.')
    setBusy(true)
    try {
      await rejectLoan(supabase, loan.id, reason.trim())
      onActioned?.()
    } catch (err) {
      setError(err?.message || 'Could not reject the loan.')
    } finally {
      setBusy(false)
    }
  }

  const willFinalize = loan.approvalsCount + 1 >= loan.requiredApprovals
  const approveLabel = busy
    ? hasPriorApproval ? 'Confirming…' : 'Approving…'
    : willFinalize
      ? hasPriorApproval
        ? `Confirm & disburse (${loan.approvalsCount + 1}/${loan.requiredApprovals})`
        : `Approve & disburse (${loan.approvalsCount + 1}/${loan.requiredApprovals})`
      : `Submit approval (${loan.approvalsCount + 1}/${loan.requiredApprovals})`

  let approvalNote = null
  if (loan.isSelf) {
    approvalNote = 'You can\'t approve your own loan.'
  } else if (loan.iApproved) {
    approvalNote = `You've already approved (${loan.approvalsCount}/${loan.requiredApprovals}). Awaiting another admin.`
  } else if (hasPriorApproval) {
    approvalNote = `Approved by ${loan.approverNames.join(', ')} (${loan.approvalsCount}/${loan.requiredApprovals}).`
  }

  return (
    <div className="rounded-xl border border-gray-200 p-4 space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <p className="font-medium text-gray-900">{loan.memberName}</p>
            {!loan.hasPriorLoan && (
              <span className="inline-flex items-center rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-700">
                First-time borrower
              </span>
            )}
          </div>
          <p className="text-xs text-gray-400">Requested {formatDate(loan.requested_at?.slice(0, 10))}</p>
        </div>
        <p className="text-lg font-semibold text-gray-900">{formatTZS(loan.principal)}</p>
      </div>

      {approvalNote && (
        <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 border border-amber-100 text-amber-800">
          {approvalNote}
        </p>
      )}

      <div className="rounded-lg bg-gray-50 p-3 text-sm space-y-1">
        <Row label="Member contribution" value={formatTZS(loan.contribution)} />
        <Row label="3× contribution" value={formatTZS(loan.contributionCeiling)} />
        <Row label="25% of pool" value={formatTZS(loan.poolCeiling)} />
        <div className="border-t border-gray-200 my-1" />
        <Row label="Max eligible" value={formatTZS(loan.maxEligible)} />
        <Row label="Requested" value={formatTZS(loan.principal)} danger={overLimit} />
        {overLimit && (
          <p className="text-xs text-red-600">
            Exceeds the {contribBinds ? '3× contribution' : '25% of pool'} cap; the database will
            reject the approval.
          </p>
        )}
      </div>

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
        <div className="space-y-3">
          {hasPriorApproval ? (
            <div>
              <p className="text-sm font-medium text-gray-700 mb-1">Disbursement proof (from first approver)</p>
              {proofUrl ? (
                <a href={proofUrl} target="_blank" rel="noreferrer">
                  <img src={proofUrl} alt="Disbursement proof" className="max-h-48 rounded-lg border border-gray-100" />
                </a>
              ) : (
                <button
                  onClick={viewProof}
                  disabled={loadingProof}
                  className="text-sm text-emerald-600 hover:text-emerald-700 disabled:opacity-50"
                >
                  {loadingProof ? 'Loading…' : 'View proof'}
                </button>
              )}
            </div>
          ) : (
            <div>
              <p className="text-sm font-medium text-gray-700 mb-1">Disbursement proof</p>
              <UploadZone file={file} onSelect={setFile} />
            </div>
          )}
          {error && <p className="text-sm text-red-600">{error}</p>}
          <div className="flex gap-2">
            <button
              onClick={handleApprove}
              disabled={busy || !loan.canApprove}
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
