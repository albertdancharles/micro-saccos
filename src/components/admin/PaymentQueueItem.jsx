// Pending payment row (build plan §9, Decision #11). Multi-admin aware:
//   * 0 approvals → this admin is the first; editable amount input.
//   * 1+ approvals → the first amount wins; second admin confirms without editing.
//   * Self-submissions can never be approved by the same person.
//
// Since partial payments (migration 021) the amount no longer has to cover the
// whole obligation, so the admin gets a live preview of where it will land before
// they commit — and a hard stop when it exceeds everything that could be settled,
// which is what the RPC would reject anyway.
import { useState } from 'react'
import { supabase } from '../../supabaseClient'
import { formatTZS, formatMonth, formatDate } from '../../lib/format'
import { approveSubmission, rejectSubmission } from '../../lib/payments'
import { allocateFeePayment, allocateInstallmentPayment } from '../../lib/allocation'
import { useSignedProof } from '../../hooks/useSignedProof'
import { useLanguage } from '../../hooks/useLanguage'

const TYPE_LABEL = {
  savings_deposit: 'Savings deposit',
  monthly_fee: 'Monthly fee',
  loan_installment: 'Loan repayment',
}

// One line of the allocation preview: "to penalty · 1,000".
function AllocRow({ label, value, tone }) {
  const color =
    tone === 'red' ? 'text-red-600' : tone === 'emerald' ? 'text-emerald-700' : 'text-slate-600'
  return (
    <div className="flex justify-between">
      <span className={color}>{label}</span>
      <span className={`tabular-nums ${color}`}>{formatTZS(value)}</span>
    </div>
  )
}

export default function PaymentQueueItem({ submission, onActioned }) {
  const { t } = useLanguage()
  const firstAmount = submission.firstAmount
  const hasPriorApproval = submission.approvalsCount > 0
  const lockedAmount = hasPriorApproval ? Number(firstAmount) : null

  const [amount, setAmount] = useState(
    hasPriorApproval ? String(firstAmount) : String(submission.suggested),
  )
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  const { proofUrl, loadingProof, viewProof, error: proofError } = useSignedProof()

  // Preview the waterfall for the amount currently in the box. Null for savings
  // deposits, which have no obligation to allocate against.
  const previewAmount = hasPriorApproval ? lockedAmount : Number(amount)
  let allocation = null
  if (submission.obligation && previewAmount > 0) {
    allocation =
      submission.submission_type === 'monthly_fee'
        ? allocateFeePayment(previewAmount, submission.obligation)
        : allocateInstallmentPayment(
            previewAmount,
            submission.obligation,
            submission.outstanding,
          )
  }
  const overCeiling = !!allocation && allocation.excess > 0

  async function handleApprove() {
    setError('')
    const amt = hasPriorApproval ? lockedAmount : Number(amount)
    if (!(amt > 0)) return setError(t('Enter the amount received.'))
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
    if (!reason.trim()) return setError(t('Add a short reason for the rejection.'))
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
    ? t('Approving…')
    : willFinalize
      ? t('Approve ({a}/{r})')
          .replace('{a}', submission.approvalsCount + 1)
          .replace('{r}', submission.requiredApprovals)
      : t('Submit approval ({a}/{r})')
          .replace('{a}', submission.approvalsCount + 1)
          .replace('{r}', submission.requiredApprovals)

  let approvalNote = null
  if (submission.isSelf) {
    approvalNote = t("You can't approve your own submission.")
  } else if (submission.iApproved) {
    approvalNote = t("You've already approved ({a}/{r}). Awaiting another admin.")
      .replace('{a}', submission.approvalsCount)
      .replace('{r}', submission.requiredApprovals)
  } else if (hasPriorApproval) {
    approvalNote = t('Approved by {names} ({a}/{r}).')
      .replace('{names}', submission.approverNames.join(', '))
      .replace('{a}', submission.approvalsCount)
      .replace('{r}', submission.requiredApprovals)
  }

  return (
    <div className="rounded-xl border border-slate-200/80 bg-white p-4 space-y-3 transition-shadow hover:shadow-[0_1px_3px_rgba(15,23,42,0.04),0_4px_12px_-6px_rgba(15,23,42,0.08)]">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="font-medium text-slate-900">{submission.memberName}</p>
          <p className="text-xs text-slate-500 mt-0.5">
            {t(TYPE_LABEL[submission.submission_type])}
            {submission.submission_type === 'monthly_fee' && submission.period && (
              <> · {t('for {month}').replace('{month}', formatMonth(submission.period))}</>
            )}
            {submission.submission_type === 'loan_installment' && submission.installmentNumber && (
              <>
                {' '}· #{submission.installmentNumber}
                {submission.dueDate
                  ? ` · ${t('due')} ${formatDate(submission.dueDate)}`
                  : ''}
              </>
            )}
          </p>
        </div>
        <div className="text-right shrink-0">
          <p className="text-[11px] uppercase tracking-wide text-slate-400">{t('Claimed')}</p>
          <p className="font-semibold text-slate-900 tabular-nums">
            {formatTZS(submission.amount_claimed)}
          </p>
          {submission.penalty > 0 && (
            <p className="text-xs text-red-600 tabular-nums">
              {t('incl. {p} penalty').replace('{p}', formatTZS(submission.penalty))}
            </p>
          )}
        </div>
      </div>

      {approvalNote && (
        <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 ring-1 ring-inset ring-amber-200/70 text-amber-800">
          {approvalNote}
        </p>
      )}

      {proofUrl ? (
        <a href={proofUrl} target="_blank" rel="noreferrer">
          <img
            src={proofUrl}
            alt="Payment proof"
            className="max-h-48 rounded-lg border border-slate-100"
          />
        </a>
      ) : (
        <div>
          <button
            onClick={() => viewProof(submission.proof_url)}
            disabled={loadingProof}
            className="text-sm font-medium text-emerald-700 hover:text-emerald-800 hover:underline underline-offset-2 disabled:opacity-50"
          >
            {loadingProof ? t('Loading…') : t('View screenshot')}
          </button>
          {proofError && <p className="mt-1 text-sm text-red-600">{proofError}</p>}
        </div>
      )}

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
        <div className="space-y-2">
          <label
            htmlFor={`pay-amount-${submission.id}`}
            className="block text-sm font-medium text-slate-700"
          >
            {t('Amount received (TSh)')}
          </label>
          {hasPriorApproval ? (
            <p className="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-slate-900 tabular-nums">
              {formatTZS(lockedAmount)}{' '}
              <span className="text-xs text-slate-400">{t('(locked by first approver)')}</span>
            </p>
          ) : (
            <input
              id={`pay-amount-${submission.id}`}
              type="number"
              min="0"
              inputMode="numeric"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              disabled={!submission.canApprove}
              className="input-field tabular-nums"
            />
          )}
          {allocation && !overCeiling && (
            <div className="rounded-lg bg-slate-50 ring-1 ring-inset ring-slate-100 p-2.5 text-xs space-y-0.5">
              {allocation.penalty > 0 && (
                <AllocRow label={t('to penalty')} value={allocation.penalty} tone="red" />
              )}
              {allocation.interest > 0 && (
                <AllocRow label={t('to interest')} value={allocation.interest} />
              )}
              {allocation.base > 0 && <AllocRow label={t('to the fee')} value={allocation.base} />}
              {allocation.principal > 0 && (
                <AllocRow label={t('to principal')} value={allocation.principal} />
              )}
              {allocation.extraPrincipal > 0 && (
                <AllocRow
                  label={t('to principal (early)')}
                  value={allocation.extraPrincipal}
                  tone="emerald"
                />
              )}
              <p className={`pt-1 ${allocation.remaining > 0 ? 'text-sky-700' : 'text-emerald-700'}`}>
                {allocation.remaining > 0
                  ? t('{amount} will still be owed — marked part paid.').replace(
                      '{amount}',
                      formatTZS(allocation.remaining),
                    )
                  : t('Settles this in full.')}
              </p>
            </div>
          )}
          {overCeiling && (
            <p className="text-xs text-red-600">
              {t('{amount} more than anything outstanding. Approve the exact amount and log the surplus as a savings deposit.')
                .replace('{amount}', formatTZS(allocation.excess))}
            </p>
          )}
          {error && <p className="text-sm text-red-600">{error}</p>}
          <div className="flex gap-2 pt-1">
            <button
              onClick={handleApprove}
              disabled={busy || !submission.canApprove || overCeiling}
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
