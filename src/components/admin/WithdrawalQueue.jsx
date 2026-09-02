// Withdrawal requests (migration 025). Two stages, deliberately separate:
//   pending  → 2-of-N approval authorises the payment
//   approved → an admin pays out and attaches the M-Pesa proof; ONLY THEN does the
//              member's balance and the pool actually move.
import { useState } from 'react'
import { supabase } from '../../supabaseClient'
import { formatTZS, formatDate } from '../../lib/format'
import { approveWithdrawal, rejectWithdrawal, markWithdrawalPaid } from '../../lib/withdrawals'
import { buildPayoutPath, uploadPaymentProof } from '../../lib/storage'
import UploadZone from '../ui/UploadZone'
import Badge from '../ui/Badge'
import { useLanguage } from '../../hooks/useLanguage'

function WithdrawalItem({ request, onActioned }) {
  const { t } = useLanguage()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  const [file, setFile] = useState(null)

  const isApproved = request.status === 'approved'

  async function run(fn) {
    setError('')
    setBusy(true)
    try {
      await fn()
      onActioned?.()
    } catch (err) {
      setError(err?.message || t('Could not complete that.'))
    } finally {
      setBusy(false)
    }
  }

  async function handlePayout() {
    if (!file) return setError(t('Upload the payout screenshot.'))
    await run(async () => {
      const path = buildPayoutPath(request.is_exit ? 'exit' : 'withdrawal', request.id, file)
      await uploadPaymentProof(supabase, file, path)
      await markWithdrawalPaid(supabase, request.id, path)
    })
  }

  const willFinalize = request.approvalsCount + 1 >= request.requiredApprovals
  const approveLabel = busy
    ? t('Working…')
    : willFinalize
      ? t('Approve & apply ({a}/{r})')
          .replace('{a}', request.approvalsCount + 1)
          .replace('{r}', request.requiredApprovals)
      : t('Submit approval ({a}/{r})')
          .replace('{a}', request.approvalsCount + 1)
          .replace('{r}', request.requiredApprovals)

  let note = null
  if (request.isSelf) {
    note = t('This is your own withdrawal — another admin must handle it.')
  } else if (request.iApproved) {
    note = t("You've already approved ({a}/{r}). Awaiting another admin.")
      .replace('{a}', request.approvalsCount)
      .replace('{r}', request.requiredApprovals)
  } else if (request.approvalsCount > 0) {
    note = t('Approved by {names} ({a}/{r}).')
      .replace('{names}', request.approverNames.join(', '))
      .replace('{a}', request.approvalsCount)
      .replace('{r}', request.requiredApprovals)
  }

  return (
    <div className="rounded-xl border border-slate-200/80 bg-white p-4 space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="font-medium text-slate-900">
            {request.memberName}
            {request.is_exit && (
              <span className="ml-2 text-xs font-normal text-amber-700">
                {t('exit settlement')}
              </span>
            )}
          </p>
          <p className="text-xs text-slate-500 mt-0.5">
            {formatDate(request.created_at?.slice(0, 10))} · {request.reason}
          </p>
        </div>
        <div className="text-right shrink-0">
          <p className="font-semibold text-slate-900 tabular-nums">{formatTZS(request.amount)}</p>
          <Badge status={isApproved ? 'approved' : 'pending'} />
        </div>
      </div>

      {note && (
        <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 ring-1 ring-inset ring-amber-200/70 text-amber-800">
          {note}
        </p>
      )}

      {request.is_exit && (
        <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 ring-1 ring-inset ring-amber-200/70 text-amber-800">
          {t('Paying this out settles the member in full and deactivates them. Their history is kept.')}
        </p>
      )}

      {error && <p className="text-sm text-red-600">{error}</p>}

      {rejecting ? (
        <div className="space-y-2">
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={2}
            placeholder={t('Reason for rejection')}
            className="input-field"
          />
          <div className="flex gap-2">
            <button
              onClick={() => {
                if (!reason.trim()) return setError(t('Add a short reason for the rejection.'))
                run(() => rejectWithdrawal(supabase, request.id, reason.trim()))
              }}
              disabled={busy}
              className="btn-danger flex-1"
            >
              {busy ? t('Working…') : t('Confirm reject')}
            </button>
            <button onClick={() => setRejecting(false)} className="btn-secondary flex-1">
              {t('Cancel')}
            </button>
          </div>
        </div>
      ) : isApproved ? (
        <div className="space-y-2">
          <UploadZone file={file} onSelect={setFile} />
          <div className="flex gap-2">
            <button
              onClick={handlePayout}
              disabled={busy || !request.canPayout}
              className="btn-primary flex-1"
            >
              {busy ? t('Working…') : t('Record payout')}
            </button>
            <button onClick={() => setRejecting(true)} className="btn-secondary">
              {t('Reject')}
            </button>
          </div>
        </div>
      ) : (
        // Stacked below sm — see CorrectionsPanel. "Idhinisha & tekeleza (1/2)"
        // beside "Kataa" fits only just, and nowrap buttons cannot shrink.
        <div className="flex flex-col gap-2 sm:flex-row">
          <button
            onClick={() => run(() => approveWithdrawal(supabase, request.id))}
            disabled={busy || !request.canApprove}
            className="btn-info sm:flex-1"
          >
            {approveLabel}
          </button>
          <button onClick={() => setRejecting(true)} className="btn-secondary">
            {t('Reject')}
          </button>
        </div>
      )}
    </div>
  )
}

export default function WithdrawalQueue({ pendingWithdrawals, onActioned }) {
  const { t } = useLanguage()
  if (!pendingWithdrawals || pendingWithdrawals.length === 0) return null

  return (
    <section className="rounded-2xl border border-sky-200/70 bg-white p-4 sm:p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-sky-700 mb-3">
        {t('Withdrawals ({n})').replace('{n}', pendingWithdrawals.length)}
      </h2>
      <div className="space-y-3">
        {pendingWithdrawals.map((r) => (
          <WithdrawalItem key={r.id} request={r} onActioned={onActioned} />
        ))}
      </div>
    </section>
  )
}
