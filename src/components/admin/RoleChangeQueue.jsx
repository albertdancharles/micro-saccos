// Pending admin role-change requests. Same 2-of-N pattern as savings/pool
// edits: requester does NOT auto-vote, target can't approve, any admin can
// cancel a pending request.
import { supabase } from '../../supabaseClient'
import { formatDate } from '../../lib/format'
import { approveRoleChange, cancelRoleChange } from '../../lib/admin'
import { useTwoStepAction } from '../../hooks/useTwoStepAction'
import { useLanguage } from '../../hooks/useLanguage'

function ChangeItem({ request, onActioned }) {
  const { t } = useLanguage()
  const { busy, error, handleApprove, handleCancel } = useTwoStepAction({
    onApprove: async () => {
      await approveRoleChange(supabase, request.id)
      onActioned?.()
    },
    onCancel: async () => {
      await cancelRoleChange(supabase, request.id)
      onActioned?.()
    },
    confirmCancel: t('Cancel this role-change request?'),
    approveError: t('Could not approve the role change.'),
    cancelError: t('Could not cancel.'),
  })

  const isPromote = request.change_type === 'promote'

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
    note = t("This change targets you — you can't approve it.")
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

  const title = isPromote
    ? t('Promote {name}').replace('{name}', request.targetName)
    : t('Revoke admin from {name}').replace('{name}', request.targetName)

  return (
    <div
      className={`rounded-xl border p-4 space-y-3 ${
        isPromote
          ? 'border-emerald-200/80 bg-emerald-50/40'
          : 'border-red-200/80 bg-red-50/40'
      }`}
    >
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-medium text-slate-900">{title}</p>
          <p className="text-xs text-slate-500 mt-0.5">
            {t('Requested by {name} · {date}')
              .replace('{name}', request.requesterName)
              .replace('{date}', formatDate(request.created_at?.slice(0, 10)))}
          </p>
        </div>
        <span
          className={`inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide ring-1 ring-inset ${
            isPromote
              ? 'bg-emerald-50 text-emerald-700 ring-emerald-200'
              : 'bg-red-50 text-red-700 ring-red-200'
          }`}
        >
          {isPromote ? t('promote') : t('revoke')}
        </span>
      </div>

      {note && (
        <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 ring-1 ring-inset ring-amber-200/70 text-amber-800">
          {note}
        </p>
      )}

      {request.reason && (
        <div className="rounded-lg bg-white ring-1 ring-inset ring-slate-100 p-3">
          <p className="text-xs text-slate-500">
            <span className="font-medium text-slate-700">{t('Reason:')}</span> {request.reason}
          </p>
        </div>
      )}

      {error && <p className="text-sm text-red-600">{error}</p>}

      {/* Stacked below sm — see CorrectionsPanel: nowrap approval labels beside
          "Cancel request" overflow 375px. */}
      <div className="flex flex-col gap-2 sm:flex-row">
        <button
          onClick={handleApprove}
          disabled={busy || !request.canApprove}
          className={`${isPromote ? 'btn-primary' : 'btn-danger'} sm:flex-1`}
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

export default function RoleChangeQueue({ pendingRoleChanges, onActioned }) {
  const { t } = useLanguage()
  if (!pendingRoleChanges || pendingRoleChanges.length === 0) return null

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-4 sm:p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-3">
        {t('Pending role changes ({n})').replace('{n}', pendingRoleChanges.length)}
      </h2>
      <div className="space-y-3">
        {pendingRoleChanges.map((r) => (
          <ChangeItem key={r.id} request={r} onActioned={onActioned} />
        ))}
      </div>
    </section>
  )
}
