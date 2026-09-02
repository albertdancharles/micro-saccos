// Pending group-rule changes. 2-of-N approval. Requester does NOT auto-vote and
// cannot approve their own request (migration 020, same shape as PoolEditQueue).
import { supabase } from '../../supabaseClient'
import { formatTZS, formatDate } from '../../lib/format'
import { approveSettingChange, cancelSettingChange, formatSettingValue } from '../../lib/settings'
import { useTwoStepAction } from '../../hooks/useTwoStepAction'
import { useLanguage } from '../../hooks/useLanguage'

function ChangeItem({ request, onActioned }) {
  const { t } = useLanguage()
  const { busy, error, handleApprove, handleCancel } = useTwoStepAction({
    onApprove: async () => {
      await approveSettingChange(supabase, request.id)
      onActioned?.()
    },
    onCancel: async () => {
      await cancelSettingChange(supabase, request.id)
      onActioned?.()
    },
    confirmCancel: t('Cancel this rule change request?'),
    approveError: t('Could not approve the change.'),
    cancelError: t('Could not cancel.'),
  })

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
          <p className="font-medium text-slate-900">{t(request.label)}</p>
          <p className="text-xs text-slate-500 mt-0.5">
            {t('Requested by {name} · {date}')
              .replace('{name}', request.requesterName)
              .replace('{date}', formatDate(request.created_at?.slice(0, 10)))}
          </p>
        </div>
        <p className="text-sm font-semibold tabular-nums text-slate-900 text-right">
          <span className="text-slate-400 font-normal line-through">
            {formatSettingValue(request.key, request.old_value, formatTZS)}
          </span>{' '}
          <span className="text-sky-700">
            {formatSettingValue(request.key, request.new_value, formatTZS)}
          </span>
        </p>
      </div>

      {note && (
        <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 ring-1 ring-inset ring-amber-200/70 text-amber-800">
          {note}
        </p>
      )}

      {request.reason && (
        <p className="text-xs text-slate-500">
          <span className="font-medium text-slate-700">{t('Reason:')}</span> {request.reason}
        </p>
      )}

      <p className="text-xs text-slate-500">
        {t('Applies to future fees and loans only.')}
      </p>

      {error && <p className="text-sm text-red-600">{error}</p>}

      {/* Stacked below sm — see CorrectionsPanel: nowrap approval labels beside
          "Cancel request" overflow 375px. */}
      <div className="flex flex-col gap-2 sm:flex-row">
        <button
          onClick={handleApprove}
          disabled={busy || !request.canApprove}
          className="btn-info sm:flex-1"
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

export default function SettingChangeQueue({ pendingSettingChanges, onActioned }) {
  const { t } = useLanguage()
  if (!pendingSettingChanges || pendingSettingChanges.length === 0) return null

  return (
    <section className="rounded-2xl border border-sky-200/70 bg-white p-4 sm:p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-sky-700 mb-3">
        {t('Pending rule changes ({n})').replace('{n}', pendingSettingChanges.length)}
      </h2>
      <div className="space-y-3">
        {pendingSettingChanges.map((r) => (
          <ChangeItem key={r.id} request={r} onActioned={onActioned} />
        ))}
      </div>
    </section>
  )
}
