// Audit log page (Phase 2). Admin-only. Lists the most recent 200 actions newest
// first: who, what, when, and a human-readable summary of the details payload.
import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../supabaseClient'
import { getRecentAudit } from '../lib/audit'
import { formatTZS } from '../lib/format'
import Badge from '../components/ui/Badge'

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
}

function summary(row) {
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
      return 'Request cancelled'
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
      setError(err?.message || 'Could not load the audit log.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  return (
    <div className="min-h-screen bg-gray-50">
      <header className="bg-white border-b border-gray-100 sticky top-0 z-10">
        <div className="max-w-4xl mx-auto px-6 py-4 flex items-center justify-between">
          <div>
            <p className="text-xs text-gray-400">Micro-SACCOS · Admin</p>
            <h1 className="text-lg font-semibold text-gray-900">Audit log</h1>
          </div>
          <Link to="/admin" className="text-sm text-gray-500 hover:text-gray-700">
            ← Back
          </Link>
        </div>
      </header>

      <main className="max-w-4xl mx-auto px-6 py-6 space-y-4">
        {error && (
          <div className="rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-700">
            {error}
          </div>
        )}

        {loading ? (
          <p className="text-center text-gray-400 py-8">Loading…</p>
        ) : rows.length === 0 ? (
          <p className="text-center text-gray-400 py-8">No audit entries yet.</p>
        ) : (
          <section className="rounded-2xl border border-gray-100 bg-white">
            <ul className="divide-y divide-gray-50">
              {rows.map((r) => (
                <li key={r.id} className="p-4 flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className="text-sm font-medium text-gray-900">
                        {ACTION_LABEL[r.action] || r.action}
                      </span>
                      <Badge status={ACTION_BADGE[r.action] || 'pending'} />
                    </div>
                    <p className="text-xs text-gray-500 mt-0.5">{summary(r)}</p>
                    <p className="text-xs text-gray-400 mt-0.5">
                      by {actors[r.actor_id] || (r.actor_id ? 'unknown' : 'system')}
                    </p>
                  </div>
                  <p className="text-xs text-gray-400 shrink-0 whitespace-nowrap">{formatWhen(r.at)}</p>
                </li>
              ))}
            </ul>
          </section>
        )}
      </main>
    </div>
  )
}
