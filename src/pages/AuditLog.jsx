// Audit log page (Phase 2). Admin-only. Lists the most recent 200 actions newest
// first: who, what, when, and a human-readable summary of the details payload.
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { getRecentAudit } from '../lib/audit'
import { formatTZS } from '../lib/format'
import { useLanguage } from '../hooks/useLanguage'
import Badge from '../components/ui/Badge'
import AppHeader from '../components/ui/AppHeader'

const ACTION_LABEL = {
  approve_submission: 'Approved payment',
  partial_approve_submission: 'Partially approved payment',
  reject_submission: 'Rejected payment',
  approve_loan: 'Approved loan',
  partial_approve_loan: 'Partially approved loan',
  reject_loan: 'Rejected loan',
  generate_monthly_fees: 'Generated monthly fees',
  update_phone: 'Updated phone',
  create_member: 'Added member',
  request_member_deletion: 'Requested member deletion',
  partial_approve_member_deletion: 'Partially approved deletion',
  execute_member_deletion: 'Deleted member',
  cancel_member_deletion: 'Cancelled deletion',
  request_savings_edit: 'Requested savings edit',
  partial_approve_savings_edit: 'Partially approved savings edit',
  execute_savings_edit: 'Applied savings edit',
  cancel_savings_edit: 'Cancelled savings edit',
  request_pool_edit: 'Requested pool edit',
  partial_approve_pool_edit: 'Partially approved pool edit',
  execute_pool_edit: 'Applied pool edit',
  cancel_pool_edit: 'Cancelled pool edit',
  request_role_change: 'Requested role change',
  partial_approve_role_change: 'Partially approved role change',
  execute_role_change: 'Applied role change',
  cancel_role_change: 'Cancelled role change',
  send_due_reminders: 'Queued due reminders',
  dispatch_notifications: 'Sent reminders',
  schedule_notification_drain: 'Scheduled reminder delivery',

  // The admin mandate (034–037). Every one of these is an admin writing on a
  // member's behalf, which is precisely what the audit log exists to make legible
  // now that members cannot write at all.
  record_payment: 'Recorded payment',
  record_fee_payments: 'Recorded monthly fees',
  file_loan: 'Filed loan',
  admin_request_withdrawal: 'Opened withdrawal',
  request_payment_void: 'Requested correction',
  partial_approve_payment_void: 'Partially approved correction',
  execute_payment_void: 'Applied correction',
  cancel_payment_void: 'Cancelled correction',
  admin_mandate_lockdown: 'Admin mandate applied',
  drop_guarantors: 'Guarantees removed',
}

const ACTION_BADGE = {
  approve_submission: 'approved',
  approve_loan: 'approved',
  reject_submission: 'rejected',
  reject_loan: 'rejected',
  partial_approve_submission: 'pending',
  partial_approve_loan: 'pending',
  generate_monthly_fees: 'pending',
  update_phone: 'pending',
  create_member: 'approved',
  request_member_deletion: 'pending',
  partial_approve_member_deletion: 'pending',
  execute_member_deletion: 'rejected',
  cancel_member_deletion: 'pending',
  request_savings_edit: 'pending',
  partial_approve_savings_edit: 'pending',
  execute_savings_edit: 'approved',
  cancel_savings_edit: 'pending',
  request_pool_edit: 'pending',
  partial_approve_pool_edit: 'pending',
  execute_pool_edit: 'approved',
  cancel_pool_edit: 'pending',
  request_role_change: 'pending',
  partial_approve_role_change: 'pending',
  execute_role_change: 'approved',
  cancel_role_change: 'pending',
  // "Queued" is honest about what the sweep does: it fills the outbox, it does not
  // deliver. Only dispatch_notifications means a message actually left the system.
  send_due_reminders: 'queued',
  dispatch_notifications: 'sent',
  schedule_notification_drain: 'approved',

  record_payment: 'approved',
  record_fee_payments: 'approved',
  file_loan: 'pending',
  admin_request_withdrawal: 'pending',
  request_payment_void: 'pending',
  partial_approve_payment_void: 'pending',
  // Red, like execute_member_deletion: a void takes money back out of a settled
  // position, and that should catch the eye when scanning the log.
  execute_payment_void: 'rejected',
  cancel_payment_void: 'pending',
  admin_mandate_lockdown: 'approved',
  drop_guarantors: 'rejected',
}

function summary(row, t) {
  const d = row.details || {}
  switch (row.action) {
    case 'approve_submission':
      return `${d.submission_type || 'payment'} · received ${formatTZS(d.amount_received ?? 0)}`
    case 'reject_submission':
      return `${d.submission_type || 'payment'} · reason: ${d.reason || '—'}`
    case 'approve_loan':
      return `principal ${formatTZS(d.principal ?? 0)}`
    case 'reject_loan':
      return `principal ${formatTZS(d.principal ?? 0)} · reason: ${d.reason || '—'}`
    case 'generate_monthly_fees':
      return `${d.count ?? 0} fee row(s) for ${d.period || ''}`
    case 'update_phone':
      return `${d.old || '—'} → ${d.new || '—'}`
    case 'create_member':
      return `${d.full_name || ''} (${d.email || ''})`
    case 'request_member_deletion':
      return `${d.target_name || ''}${d.reason ? ` · reason: ${d.reason}` : ''}`
    case 'partial_approve_member_deletion':
      return `${d.approvals}/${d.required} approved`
    case 'execute_member_deletion':
      return `${d.full_name || ''} (${d.email || ''}) · role: ${d.role || '—'}`
    case 'cancel_member_deletion':
      return t('Request cancelled')
    case 'request_savings_edit':
      return `${d.target_name || ''} · ${Number(d.delta || 0) >= 0 ? '+' : ''}${formatTZS(d.delta || 0)} · reason: ${d.reason || '—'}`
    case 'partial_approve_savings_edit':
      return `${d.approvals}/${d.required} approved`
    case 'execute_savings_edit':
      return `${Number(d.delta || 0) >= 0 ? '+' : ''}${formatTZS(d.delta || 0)} · reason: ${d.reason || '—'}`
    case 'cancel_savings_edit':
      return t('Request cancelled')
    case 'request_pool_edit':
      return `${Number(d.delta || 0) >= 0 ? '+' : ''}${formatTZS(d.delta || 0)} · reason: ${d.reason || '—'}`
    case 'partial_approve_pool_edit':
      return `${d.approvals}/${d.required} approved`
    case 'execute_pool_edit':
      return `${Number(d.delta || 0) >= 0 ? '+' : ''}${formatTZS(d.delta || 0)} · reason: ${d.reason || '—'}`
    case 'cancel_pool_edit':
      return t('Request cancelled')
    case 'request_role_change':
      return `${d.target_name || ''} · ${d.change_type || ''} · reason: ${d.reason || '—'}`
    case 'partial_approve_role_change':
      return `${d.approvals}/${d.required} approved`
    case 'execute_role_change':
      return `${d.change_type || ''} → ${d.new_role || '—'}`
    case 'cancel_role_change':
      return t('Request cancelled')
    case 'record_payment':
      return `${d.submission_type || 'payment'} · ${formatTZS(d.amount ?? 0)}${
        d.self_recorded ? ' · own money' : ''
      } · ${d.settled ? 'settled' : `${d.approvals}/${d.required} signed`}`
    case 'record_fee_payments':
      return `${d.entries ?? 0} fee payment(s)`
    case 'file_loan':
      return `principal ${formatTZS(d.principal ?? 0)}`
    case 'admin_request_withdrawal':
      return `${formatTZS(d.amount ?? 0)} · reason: ${d.reason || '—'}`
    case 'request_payment_void':
      return `reason: ${d.reason || '—'}`
    case 'partial_approve_payment_void':
      return `${d.approvals} approved`
    case 'execute_payment_void':
      // Show the allocation that was reversed, not just the gross amount: it is
      // the four figures the waterfall actually moved.
      return `${d.submission_type || 'payment'} · ${formatTZS(d.amount ?? 0)} reversed (base ${formatTZS(
        d.applied_base ?? 0,
      )}, penalty ${formatTZS(d.applied_penalty ?? 0)}, interest ${formatTZS(
        d.applied_interest ?? 0,
      )}, principal ${formatTZS(d.applied_principal ?? 0)}) · reason: ${d.reason || '—'}`
    case 'cancel_payment_void':
      return t('Request cancelled')
    case 'admin_mandate_lockdown':
      return `${d.submissions_rejected ?? 0} payment(s), ${d.loans_rejected ?? 0} loan(s), ${
        d.withdrawals_rejected ?? 0
      } withdrawal(s) retired`
    case 'drop_guarantors':
      return `${d.pledges_dropped ?? 0} pledge(s) released`
    case 'send_due_reminders':
      // Says "queued", not "sent" — this step never touches a phone.
      return `${d.reminders ?? 0} ${t('queued for delivery')} · ${t('week')} ${d.week || '—'}`
    case 'dispatch_notifications': {
      const parts = [`${d.sent ?? 0} ${t('sent')}`]
      if (d.failed) parts.push(`${d.failed} ${t('failed')}`)
      if (d.skipped) parts.push(`${d.skipped} ${t('skipped')}`)
      if (d.stale) parts.push(`${d.stale} ${t('expired unsent')}`)
      if (d.blocked) parts.push(d.blocked)
      return parts.join(' · ')
    }
    case 'schedule_notification_drain':
      return `${t('every')} ${d.schedule || '—'}`
    default:
      return JSON.stringify(d)
  }
}

function formatWhen(at) {
  if (!at) return ''
  const d = new Date(at)
  // Display in EAT (Africa/Dar_es_Salaam, UTC+3) so timestamps match the dashboard.
  return new Intl.DateTimeFormat('en-GB', {
    day: 'numeric',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
    timeZone: 'Africa/Dar_es_Salaam',
  }).format(d)
}

export default function AuditLog() {
  const { t } = useLanguage()
  const [rows, setRows] = useState([])
  const [actors, setActors] = useState({})
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const load = useCallback(async () => {
    if (!supabase) return
    try {
      const { rows, actors } = await getRecentAudit(supabase, 200)
      setRows(rows)
      setActors(actors)
      setError(null)
    } catch (err) {
      console.error('Failed to load audit log', err)
      setError(err?.message || t('Could not load the audit log.'))
    } finally {
      setLoading(false)
    }
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  return (
    <div className="min-h-dvh bg-[var(--color-app-bg)]">
      <AppHeader
        eyebrow={t('Micro-SACCOS · Admin')}
        title={t('Audit log')}
        width="max-w-4xl"
        back={{ to: '/admin', label: t('← Back') }}
        showControls={false}
      />

      <main className="max-w-4xl mx-auto px-4 sm:px-6 py-5 sm:py-6 space-y-4 pb-safe">
        {error && (
          <div className="rounded-xl border border-red-200/70 bg-red-50 p-3 text-sm text-red-700">
            {error}
          </div>
        )}

        {loading ? (
          <p className="text-center text-slate-400 py-8">{t('Loading…')}</p>
        ) : rows.length === 0 ? (
          <p className="text-center text-slate-400 py-8">{t('No audit entries yet.')}</p>
        ) : (
          <section className="rounded-2xl border border-slate-200/70 bg-white shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
            <ul className="divide-y divide-slate-100">
              {rows.map((r) => (
                <li
                  key={r.id}
                  className="px-5 py-4 flex items-start justify-between gap-3 transition-colors hover:bg-slate-50/60"
                >
                  <div className="min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className="text-sm font-medium text-slate-900">
                        {t(ACTION_LABEL[r.action] || r.action)}
                      </span>
                      <Badge status={ACTION_BADGE[r.action] || 'pending'} />
                    </div>
                    <p className="text-xs text-slate-500 mt-0.5">{summary(r, t)}</p>
                    <p className="text-xs text-slate-400 mt-0.5">
                      {t('by')} {actors[r.actor_id] || (r.actor_id ? t('unknown') : t('system'))}
                    </p>
                  </div>
                  <p className="text-xs text-slate-400 shrink-0 whitespace-nowrap tabular-nums">
                    {formatWhen(r.at)}
                  </p>
                </li>
              ))}
            </ul>
          </section>
        )}
      </main>
    </div>
  )
}
