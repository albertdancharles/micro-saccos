// Pending loan distress actions. 2-of-N approval. Neither the requester nor the
// borrower may vote (migration 022, same shape as PoolEditQueue).
import { supabase } from '../../supabaseClient'
import { formatTZS, formatDate } from '../../lib/format'
import { approveLoanAction, cancelLoanAction } from '../../lib/loanActions'
import { useTwoStepAction } from '../../hooks/useTwoStepAction'
import { useLanguage } from '../../hooks/useLanguage'

function ActionItem({ request, onActioned }) {
  const { t } = useLanguage()
  const { busy, error, handleApprove, handleCancel } = useTwoStepAction({
    onApprove: async () => {
      await approveLoanAction(supabase, request.id)
      onActioned?.()
    },
    onCancel: async () => {
      await cancelLoanAction(supabase, request.id)
      onActioned?.()
    },
    confirmCancel: t('Cancel this loan action request?'),
    approveError: t('Could not approve the action.'),
    cancelError: t('Could not cancel.'),
  })

  const title =
    request.action === 'restructure'
      ? t('Reschedule {name}’s loan').replace('{name}', request.memberName)
      : request.action === 'write_off'
        ? t('Write off {name}’s loan').replace('{name}', request.memberName)
        : t('Recover from {name}’s savings').replace('{name}', request.memberName)

  const effect =
    request.action === 'restructure'
      ? t('New schedule over {n} month(s) on {amount} outstanding. Unpaid installments and their accrued penalty are cancelled.')
          .replace('{n}', request.term_months)
          .replace('{amount}', formatTZS(request.outstanding))
      : request.action === 'write_off'
        ? t('The pool permanently absorbs {amount}.').replace(
            '{amount}',
            formatTZS(request.outstanding),
          )
        : t('{amount} moves from their savings to the loan balance. No cash moves.').replace(
            '{amount}',
            formatTZS(Math.min(Number(request.amount), request.outstanding, request.memberSavings)),
          )

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
  } else if (request.isBorrower) {
    note = t('This is your own loan — you cannot vote on it.')
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
      <div>
        <p className="font-medium text-slate-900">{title}</p>
        <p className="text-xs text-slate-500 mt-0.5">
          {t('Requested by {name} · {date}')
            .replace('{name}', request.requesterName)
            .replace('{date}', formatDate(request.created_at?.slice(0, 10)))}
        </p>
      </div>

      {note && (
        <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 ring-1 ring-inset ring-amber-200/70 text-amber-800">
          {note}
        </p>
      )}

      <div
        className={`rounded-lg p-3 text-xs ring-1 ring-inset ${
          request.action === 'write_off'
            ? 'bg-red-50 ring-red-200/70 text-red-800'
            : 'bg-slate-50 ring-slate-100 text-slate-600'
        }`}
      >
        <p>{effect}</p>
        {request.reason && (
          <p className="mt-2">
            <span className="font-medium">{t('Reason:')}</span> {request.reason}
          </p>
        )}
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="flex gap-2">
        <button
          onClick={handleApprove}
          disabled={busy || !request.canApprove}
          className={request.action === 'write_off' ? 'btn-danger flex-1' : 'btn-info flex-1'}
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

export default function LoanActionQueue({ pendingLoanActions, onActioned }) {
  const { t } = useLanguage()
  if (!pendingLoanActions || pendingLoanActions.length === 0) return null

  return (
    <section className="rounded-2xl border border-amber-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-amber-700 mb-3">
        {t('Pending loan actions ({n})').replace('{n}', pendingLoanActions.length)}
      </h2>
      <div className="space-y-3">
        {pendingLoanActions.map((r) => (
          <ActionItem key={r.id} request={r} onActioned={onActioned} />
        ))}
      </div>
    </section>
  )
}
