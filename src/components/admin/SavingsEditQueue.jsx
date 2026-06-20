// Pending savings-edit requests. 2-of-N approval pattern, but stricter than
// the rest of the system: the requester does NOT auto-vote, and neither the
// requester nor the target can approve. Any admin can cancel a pending request.
import { supabase } from '../../supabaseClient'
import { formatTZS, formatDate } from '../../lib/format'
import { approveSavingsEdit, cancelSavingsEdit } from '../../lib/admin'
import { useTwoStepAction } from '../../hooks/useTwoStepAction'
import { useLanguage } from '../../hooks/useLanguage'

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
  const { t } = useLanguage()
  const { busy, error, handleApprove, handleCancel } = useTwoStepAction({
    onApprove: async () => {
      await approveSavingsEdit(supabase, request.id)
      onActioned?.()
    },
    onCancel: async () => {
      await cancelSavingsEdit(supabase, request.id)
      onActioned?.()
    },
    confirmCancel: t('Cancel this savings edit request?'),
    approveError: t('Could not approve the edit.'),
    cancelError: t('Could not cancel.'),
  })

  const delta = Number(request.delta)
  const projected = Number(request.currentSavings) + delta

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
  if (request.isRequester) {
    note = t("You opened this request — you can't vote on it. Awaiting other admins.")
  } else if (request.isTarget) {
    note = t("This edit targets your own savings — you can't approve it.")
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
        <div>
          <p className="font-medium text-slate-900">
            {t("Edit {name}'s savings").replace('{name}', request.targetName)}
          </p>
          <p className="text-xs text-slate-500 mt-0.5">
            {t('Requested by {name} · {date}')
              .replace('{name}', request.requesterName)
              .replace('{date}', formatDate(request.created_at?.slice(0, 10)))}
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
        <Row label={t('Current savings')} value={formatTZS(request.currentSavings)} />
        <Row
          label={t('After edit')}
          value={formatTZS(projected)}
          danger={projected < 0}
          accent={delta > 0}
        />
        {request.reason && (
          <p className="text-xs text-slate-500 mt-2">
            <span className="font-medium text-slate-700">{t('Reason:')}</span> {request.reason}
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
          {t('Cancel request')}
        </button>
      </div>
    </div>
  )
}

export default function SavingsEditQueue({ pendingSavingsEdits, onActioned }) {
  const { t } = useLanguage()
  if (!pendingSavingsEdits || pendingSavingsEdits.length === 0) return null

  return (
    <section className="rounded-2xl border border-emerald-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-emerald-700 mb-3">
        {t('Pending savings edits ({n})').replace('{n}', pendingSavingsEdits.length)}
      </h2>
      <div className="space-y-3">
        {pendingSavingsEdits.map((r) => (
          <EditItem key={r.id} request={r} onActioned={onActioned} />
        ))}
      </div>
    </section>
  )
}
