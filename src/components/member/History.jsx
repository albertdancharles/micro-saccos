// Submission history (build plan §9). Read-only reverse-chronological list of the
// member's own payment_submissions. Refetches when `refreshKey` changes.
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../supabaseClient'
import { useAuth } from '../../hooks/useAuth'
import { getMySubmissions } from '../../lib/payments'
import Badge from '../ui/Badge'
import { formatTZS, formatDate } from '../../lib/format'

const TYPE_LABEL = {
  savings_deposit: 'Savings deposit',
  monthly_fee: 'Monthly fee',
  loan_installment: 'Loan repayment',
}

export default function History({ refreshKey }) {
  const { user } = useAuth()
  const memberId = user?.id ?? null
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    if (!supabase || !memberId) return
    try {
      setRows(await getMySubmissions(supabase, memberId))
    } catch (err) {
      console.error('Failed to load history', err)
    } finally {
      setLoading(false)
    }
  }, [memberId])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load, refreshKey])

  return (
    <section className="rounded-2xl border border-gray-100 bg-white p-4">
      <h2 className="text-sm font-semibold text-gray-900 mb-3">History</h2>
      {loading ? (
        <p className="text-sm text-gray-400">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-gray-400">No submissions yet.</p>
      ) : (
        <ul className="space-y-3">
          {rows.map((r) => (
            <li key={r.id} className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <p className="text-sm text-gray-900">{TYPE_LABEL[r.submission_type] || r.submission_type}</p>
                <p className="text-xs text-gray-400">
                  Sent {formatDate(r.submitted_at?.slice(0, 10))}
                  {r.reviewed_at ? ` · reviewed ${formatDate(r.reviewed_at.slice(0, 10))}` : ''}
                </p>
                {r.status === 'rejected' && r.rejection_reason && (
                  <p className="text-xs text-red-600">Reason: {r.rejection_reason}</p>
                )}
              </div>
              <div className="text-right shrink-0">
                <p className="text-sm font-medium text-gray-900">{formatTZS(r.amount_claimed)}</p>
                <Badge status={r.status} />
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
