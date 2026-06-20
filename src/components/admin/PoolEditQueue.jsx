// Pending pool-edit requests. 2-of-N approval. Requester does NOT auto-vote
// and cannot approve their own request.
import { supabase } from '../../supabaseClient'
import { formatTZS, formatDate } from '../../lib/format'
import { approvePoolEdit, cancelPoolEdit } from '../../lib/admin'
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
              ? 'font-semibold text-sky-700'
              : 'text-slate-900'
        }`}
      >
        {value}
      </span>
    </div>
  )
}

function EditItem({ request, stats, onActioned }) {
  const { t } = useLanguage()
  const { busy, error, handleApprove, handleCancel } = useTwoStepAction({
    onApprove: async () => {
      await approvePoolEdit(supabase, request.id)
      onActioned?.()
    },
    onCancel: async () => {
      await cancelPoolEdit(supabase, request.id)
      onActioned?.()
    },
    confirmCancel: t('Cancel this pool edit request?'),
    approveError: t('Could not approve the edit.'),
    cancelError: t('Could not cancel.'),
  })

  const delta = Number(request.delta)
  const currentPool = Number(stats?.pool ?? 0)
  const currentTotal = Number(stats?.totalAssets ?? currentPool)
  const projectedPool = currentPool + delta
  const projectedTotal = currentTotal + delta

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
          <p className="font-medium text-slate-900">{t('Adjust group pool')}</p>
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
        <Row label={t('Current pool')} value={formatTZS(currentPool)} />
        <Row
          label={t('After edit · pool')}
          value={formatTZS(projectedPool)}
          danger={projectedPool < 0}
          accent={delta > 0}
        />
        <Row label={t('Current total assets')} value={formatTZS(currentTotal)} />
        <Row
          label={t('After edit · total assets')}
          value={formatTZS(projectedTotal)}
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
          className="btn-info flex-1"
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

export default function PoolEditQueue({ pendingPoolEdits, stats, onActioned }) {
  const { t } = useLanguage()
  if (!pendingPoolEdits || pendingPoolEdits.length === 0) return null

  return (
    <section className="rounded-2xl border border-sky-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-sky-700 mb-3">
        {t('Pending total-assets edits ({n})').replace('{n}', pendingPoolEdits.length)}
      </h2>
      <div className="space-y-3">
        {pendingPoolEdits.map((r) => (
          <EditItem key={r.id} request={r} stats={stats} onActioned={onActioned} />
        ))}
      </div>
    </section>
  )
}
