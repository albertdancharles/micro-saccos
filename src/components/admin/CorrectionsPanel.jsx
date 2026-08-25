// Corrections. Two lists in one panel: voids waiting for a second signature, and
// the recent entries a void can still be raised against.
//
// This exists because the admin mandate moved the typo. When members filed their
// own payments, a wrong figure was caught before it posted — the admin read the
// screenshot and rejected it. Now the admin keys the amount, so the wrong figure
// posts, settles, and moves the pool. There was no reversal in this schema at all
// before 037.
//
// It fetches its own data rather than joining the dashboard's forty-way loader:
// nothing else needs these rows, and a correction is rare enough that loading it
// on demand is the right trade.
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../supabaseClient'
import { useAuth } from '../../hooks/useAuth'
import { useLanguage } from '../../hooks/useLanguage'
import {
  approvePaymentVoid,
  cancelPaymentVoid,
  requestPaymentVoid,
} from '../../lib/payments'
import { formatTZS, formatDate } from '../../lib/format'

const TYPE_LABEL = {
  savings_deposit: 'Savings deposit',
  monthly_fee: 'Monthly fee',
  loan_installment: 'Loan repayment',
}

export default function CorrectionsPanel({ onActioned }) {
  const { user } = useAuth()
  const { t } = useLanguage()
  const [pending, setPending] = useState([])
  const [recent, setRecent] = useState([])
  const [loading, setLoading] = useState(true)
  const [busyId, setBusyId] = useState(null)
  const [error, setError] = useState('')
  const [voidTarget, setVoidTarget] = useState(null)
  const [reason, setReason] = useState('')

  const load = useCallback(async () => {
    if (!supabase) return
    setLoading(true)
    setError('')
    try {
      const [voidRes, subRes, profRes] = await Promise.all([
        supabase
          .from('payment_voids')
          .select('*')
          .eq('status', 'pending')
          .order('created_at', { ascending: false }),
        // Only admin-recorded rows: anything with recorded_by NULL was filed by a
        // member before the mandate and carries no allocation to reverse.
        supabase
          .from('payment_submissions')
          .select('*')
          .eq('status', 'approved')
          .not('recorded_by', 'is', null)
          .order('reviewed_at', { ascending: false })
          .limit(10),
        supabase.from('profiles').select('id, full_name'),
      ])
      if (voidRes.error) throw voidRes.error
      if (subRes.error) throw subRes.error
      if (profRes.error) throw profRes.error

      const nameOf = Object.fromEntries(profRes.data.map((p) => [p.id, p.full_name]))
      const subById = Object.fromEntries(subRes.data.map((s) => [s.id, s]))

      // A pending void can point at a row older than the ten most recent, so fetch
      // any it references rather than showing a blank line.
      const missing = voidRes.data
        .map((v) => v.submission_id)
        .filter((id) => !subById[id])
      if (missing.length) {
        const { data } = await supabase
          .from('payment_submissions')
          .select('*')
          .in('id', missing)
        for (const s of data || []) subById[s.id] = s
      }

      setPending(
        voidRes.data.map((v) => ({
          ...v,
          submission: subById[v.submission_id],
          memberName: nameOf[subById[v.submission_id]?.member_id] || 'Unknown',
          requesterName: nameOf[v.requested_by] || 'Unknown',
          iRequested: v.requested_by === user?.id,
        })),
      )

      const pendingSubIds = new Set(voidRes.data.map((v) => v.submission_id))
      setRecent(
        subRes.data
          .filter((s) => !pendingSubIds.has(s.id))
          .map((s) => ({ ...s, memberName: nameOf[s.member_id] || 'Unknown' })),
      )
    } catch (err) {
      setError(err?.message || t('Could not load corrections.'))
    } finally {
      setLoading(false)
    }
  }, [user?.id, t])

  useEffect(() => {
    // load() sets a loading/reset flag synchronously before it awaits. That is
    // the one render the rule is warning about, and it is the intended one:
    // the panel must show its loading state the moment the input changes.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  async function act(fn, id) {
    setBusyId(id)
    setError('')
    try {
      await fn()
      await load()
      onActioned?.()
    } catch (err) {
      setError(err?.message || t('That did not work.'))
    } finally {
      setBusyId(null)
    }
  }

  async function submitVoid() {
    if (!reason.trim()) return setError(t('Say why this entry is being voided.'))
    const target = voidTarget
    setVoidTarget(null)
    const text = reason.trim()
    setReason('')
    await act(() => requestPaymentVoid(supabase, target.id, text), target.id)
  }

  if (loading) return <div className="skeleton h-20 w-full" />
  if (pending.length === 0 && recent.length === 0) return null

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-4 sm:p-5 shadow-card space-y-3">
      <h2 className="text-sm font-semibold text-slate-900">{t('Corrections')}</h2>

      {error && <p className="text-sm text-red-600">{error}</p>}

      {pending.length > 0 && (
        <div className="space-y-2">
          <p className="text-xs font-medium text-amber-700">
            {t('Waiting for a second signature')}
          </p>
          {pending.map((v) => (
            <div
              key={v.id}
              className="rounded-xl bg-amber-50 ring-1 ring-inset ring-amber-200/70 p-3 space-y-2"
            >
              <div className="flex justify-between gap-2 text-sm">
                <span className="text-slate-900">{v.memberName}</span>
                <span className="tabular-nums text-slate-900">
                  {formatTZS(v.submission?.amount_claimed)}
                </span>
              </div>
              <p className="text-xs text-slate-600">{v.reason}</p>
              <p className="text-xs text-slate-500">
                {t('Raised by {name}').replace('{name}', v.requesterName)}
              </p>
              {/* Stacked below sm: buttons carry white-space: nowrap, so
                  "Awaiting another admin" next to "Cancel" overflows 375px. */}
              <div className="flex flex-col gap-2 sm:flex-row">
                <button
                  onClick={() => act(() => approvePaymentVoid(supabase, v.id), v.id)}
                  disabled={busyId === v.id || v.iRequested}
                  className="btn-primary sm:flex-1 disabled:opacity-40"
                >
                  {v.iRequested ? t('Awaiting another admin') : t('Approve correction')}
                </button>
                <button
                  onClick={() => act(() => cancelPaymentVoid(supabase, v.id), v.id)}
                  disabled={busyId === v.id}
                  className="btn-secondary"
                >
                  {t('Cancel')}
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {recent.length > 0 && (
        <div className="space-y-1">
          <p className="text-xs font-medium text-slate-500">{t('Recently recorded')}</p>
          <div className="divide-y divide-slate-100">
            {recent.map((s) => (
              <div key={s.id} className="py-2 space-y-2">
                <div className="flex items-center justify-between gap-2">
                  <div className="min-w-0">
                    <p className="truncate text-sm text-slate-900">{s.memberName}</p>
                    <p className="text-xs text-slate-500">
                      {t(TYPE_LABEL[s.submission_type] || s.submission_type)}
                      {' · '}
                      {formatDate(s.reviewed_at)}
                    </p>
                  </div>
                  <div className="flex items-center gap-2 shrink-0">
                    <span className="tabular-nums text-sm text-slate-900">
                      {formatTZS(s.amount_claimed)}
                    </span>
                    <button
                      onClick={() => {
                        setVoidTarget(s)
                        setReason('')
                        setError('')
                      }}
                      className="-mr-2 inline-flex min-h-11 items-center rounded-lg px-3 text-xs font-medium text-red-600 transition-colors hover:bg-red-50 hover:text-red-700 active:bg-red-100"
                    >
                      {t('Void')}
                    </button>
                  </div>
                </div>

                {voidTarget?.id === s.id && (
                  <div className="space-y-2 rounded-lg bg-slate-50 p-2">
                    <textarea
                      value={reason}
                      onChange={(e) => setReason(e.target.value)}
                      rows={2}
                      placeholder={t('Why is this being voided?')}
                      className="input-field"
                    />
                    <div className="flex flex-col gap-2 sm:flex-row">
                      <button
                        onClick={submitVoid}
                        disabled={busyId === s.id}
                        className="btn-primary sm:flex-1"
                      >
                        {t('Request void')}
                      </button>
                      <button
                        onClick={() => setVoidTarget(null)}
                        className="btn-secondary"
                      >
                        {t('Cancel')}
                      </button>
                    </div>
                    <p className="text-xs text-slate-500">
                      {t('A second admin must approve the correction before it applies.')}
                    </p>
                  </div>
                )}
              </div>
            ))}
          </div>
        </div>
      )}
    </section>
  )
}
