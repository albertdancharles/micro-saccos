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
import { useLanguage } from '../../hooks/useLanguage'

function Row({ label, value, danger }) {
  return (
    <div className="flex justify-between">
      <span className="text-slate-500">{label}</span>
      <span
        className={`tabular-nums ${danger ? 'font-semibold text-red-600' : 'text-slate-700'}`}
      >
        {value}
      </span>
    </div>
  )
}

export default function LoanQueueItem({ loan, onActioned }) {
  const { t } = useLanguage()
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
        await approveLoan(supabase, loan.id, loan.firstProofUrl)
      } else {
        if (!file) {
          setError(t('Upload the M-Pesa disbursement screenshot first.'))
          setBusy(false)
          return
        }
        const path = buildDisbursementPath(loan.id, file)
        await uploadPaymentProof(supabase, file, path)
        await approveLoan(supabase, loan.id, path)
      }
      onActioned?.()
    } catch (err) {
      setError(err?.message || t('Could not approve the loan.'))
    } finally {
      setBusy(false)
    }
  }

  async function handleReject() {
    setError('')
    if (!reason.trim()) return setError(t('Add a short reason for the rejection.'))
    setBusy(true)
    try {
      await rejectLoan(supabase, loan.id, reason.trim())
      onActioned?.()
    } catch (err) {
      setError(err?.message || t('Could not reject the loan.'))
    } finally {
      setBusy(false)
    }
  }

  const willFinalize = loan.approvalsCount + 1 >= loan.requiredApprovals
  const approveLabel = busy
    ? hasPriorApproval
      ? t('Confirming…')
      : t('Approving…')
    : willFinalize
      ? hasPriorApproval
        ? t('Confirm & disburse ({a}/{r})')
            .replace('{a}', loan.approvalsCount + 1)
            .replace('{r}', loan.requiredApprovals)
        : t('Approve & disburse ({a}/{r})')
            .replace('{a}', loan.approvalsCount + 1)
            .replace('{r}', loan.requiredApprovals)
      : t('Submit approval ({a}/{r})')
          .replace('{a}', loan.approvalsCount + 1)
          .replace('{r}', loan.requiredApprovals)

  let approvalNote = null
  if (loan.isSelf) {
    approvalNote = t("You can't approve your own loan.")
  } else if (loan.iApproved) {
    approvalNote = t("You've already approved ({a}/{r}). Awaiting another admin.")
      .replace('{a}', loan.approvalsCount)
      .replace('{r}', loan.requiredApprovals)
  } else if (hasPriorApproval) {
    approvalNote = t('Approved by {names} ({a}/{r}).')
      .replace('{names}', loan.approverNames.join(', '))
      .replace('{a}', loan.approvalsCount)
      .replace('{r}', loan.requiredApprovals)
  }

  return (
    <div className="rounded-xl border border-slate-200/80 bg-white p-4 space-y-3 transition-shadow hover:shadow-[0_1px_3px_rgba(15,23,42,0.04),0_4px_12px_-6px_rgba(15,23,42,0.08)]">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <p className="font-medium text-slate-900">{loan.memberName}</p>
            {!loan.hasPriorLoan && (
              <span className="inline-flex items-center rounded-full bg-emerald-50 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-emerald-700 ring-1 ring-inset ring-emerald-200">
                {t('First-time borrower')}
              </span>
            )}
          </div>
          <p className="text-xs text-slate-500 mt-0.5">
            {t('Requested {date}').replace('{date}', formatDate(loan.requested_at?.slice(0, 10)))}
          </p>
        </div>
        <p className="text-lg font-semibold text-slate-900 tabular-nums shrink-0">
          {formatTZS(loan.principal)}
        </p>
      </div>

      {approvalNote && (
        <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 ring-1 ring-inset ring-amber-200/70 text-amber-800">
          {approvalNote}
        </p>
      )}

      <div className="rounded-lg bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 text-sm space-y-1">
        <Row label={t('Member savings')} value={formatTZS(loan.contribution)} />
        <Row label={t('5× savings')} value={formatTZS(loan.contributionCeiling)} />
        <Row label={t('25% of pool')} value={formatTZS(loan.poolCeiling)} />
        <div className="border-t border-slate-200 my-1" />
        <Row label={t('Max eligible')} value={formatTZS(loan.maxEligible)} />
        <Row label={t('Requested')} value={formatTZS(loan.principal)} danger={overLimit} />
        {overLimit && (
          <p className="text-xs text-red-600 pt-1">
            {t('Exceeds the {cap} cap; the database will reject the approval.')
              .replace('{cap}', contribBinds ? t('5× savings') : t('25% of pool'))}
          </p>
        )}
      </div>

      {rejecting ? (
        <div className="space-y-2">
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={2}
            placeholder={t('Reason for rejection')}
            className="input-field"
          />
          {error && <p className="text-sm text-red-600">{error}</p>}
          <div className="flex gap-2">
            <button onClick={handleReject} disabled={busy} className="btn-danger flex-1">
              {busy ? t('Rejecting…') : t('Confirm reject')}
            </button>
            <button
              onClick={() => {
                setRejecting(false)
                setError('')
              }}
              className="btn-secondary flex-1"
            >
              {t('Cancel')}
            </button>
          </div>
        </div>
      ) : (
        <div className="space-y-3">
          {hasPriorApproval ? (
            <div>
              <p className="text-sm font-medium text-slate-700 mb-1">
                {t('Disbursement proof (from first approver)')}
              </p>
              {proofUrl ? (
                <a href={proofUrl} target="_blank" rel="noreferrer">
                  <img
                    src={proofUrl}
                    alt={t('Disbursement proof')}
                    className="max-h-48 rounded-lg border border-slate-100"
                  />
                </a>
              ) : (
                <button
                  onClick={viewProof}
                  disabled={loadingProof}
                  className="text-sm font-medium text-emerald-700 hover:text-emerald-800 hover:underline underline-offset-2 disabled:opacity-50"
                >
                  {loadingProof ? t('Loading…') : t('View proof')}
                </button>
              )}
            </div>
          ) : (
            <div>
              <p className="text-sm font-medium text-slate-700 mb-1">{t('Disbursement proof')}</p>
              <UploadZone file={file} onSelect={setFile} />
            </div>
          )}
          {error && <p className="text-sm text-red-600">{error}</p>}
          <div className="flex gap-2 pt-1">
            <button
              onClick={handleApprove}
              disabled={busy || !loan.canApprove}
              className="btn-primary flex-1"
            >
              {approveLabel}
            </button>
            <button onClick={() => setRejecting(true)} className="btn-secondary">
              {t('Reject')}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
