// Submission history (build plan §9). Read-only reverse-chronological list of the
// member's own payment_submissions. Refetches when `refreshKey` changes.
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../supabaseClient'
import { useAuth } from '../../hooks/useAuth'
import { getMySubmissions } from '../../lib/payments'
import Badge from '../ui/Badge'
import { formatTZS, formatDate } from '../../lib/format'
import { useLanguage } from '../../hooks/useLanguage'

const TYPE_LABEL = {
  savings_deposit: 'Savings deposit',
  monthly_fee: 'Monthly fee',
  loan_installment: 'Loan repayment',
}

export default function History({ refreshKey, memberId: overrideMemberId = null }) {
  const { user } = useAuth()
  const { t } = useLanguage()
  const memberId = overrideMemberId ?? user?.id ?? null
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
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load, refreshKey])

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-4 sm:p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-3">{t('History')}</h2>
      {loading ? (
        <p className="text-sm text-slate-400">{t('Loading…')}</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-slate-400">{t('No submissions yet.')}</p>
      ) : (
        <ul className="divide-y divide-slate-100">
          {rows.map((r) => (
            <li
              key={r.id}
              className="flex items-start justify-between gap-3 py-3 first:pt-0 last:pb-0"
            >
              <div className="min-w-0">
                <p className="text-sm font-medium text-slate-900">
                  {t(TYPE_LABEL[r.submission_type] || r.submission_type)}
                </p>
                <p className="text-xs text-slate-500 mt-0.5">
                  {t('Sent {date}').replace('{date}', formatDate(r.submitted_at?.slice(0, 10)))}
                  {r.reviewed_at
                    ? ` · ${t('reviewed {date}').replace('{date}', formatDate(r.reviewed_at.slice(0, 10)))}`
                    : ''}
                </p>
                {r.status === 'rejected' && r.rejection_reason && (
                  <p className="text-xs text-red-600 mt-1">
                    {t('Reason: {reason}').replace('{reason}', r.rejection_reason)}
                  </p>
                )}
              </div>
              <div className="text-right shrink-0 flex flex-col items-end gap-1">
                <p className="text-sm font-semibold text-slate-900 tabular-nums">
                  {formatTZS(r.amount_claimed)}
                </p>
                <Badge status={r.status} />
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
