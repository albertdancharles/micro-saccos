// "Someone has asked you to back their loan" (migration 028).
//
// Accepting locks that much of your own savings until the loan is repaid, and the
// group can take it if the loan is written off. That is a real commitment, so the
// card says so plainly before the accept button rather than after.
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { getMyGuaranteeRequests, getMyActiveGuarantees, respondToGuarantee } from '../../lib/guarantors'
import { useLanguage } from '../../hooks/useLanguage'

const CARD =
  'rounded-2xl border border-slate-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]'

export default function GuaranteeRequestsCard({ memberId, onChanged }) {
  const { t } = useLanguage()
  const [requests, setRequests] = useState([])
  const [active, setActive] = useState([])
  const [names, setNames] = useState({})
  const [busy, setBusy] = useState(null)
  const [error, setError] = useState('')
  const [unavailable, setUnavailable] = useState(false)

  const load = useCallback(async () => {
    if (!supabase || !memberId) return
    try {
      const [reqs, act, profiles] = await Promise.all([
        getMyGuaranteeRequests(supabase, memberId),
        getMyActiveGuarantees(supabase, memberId),
        supabase.from('profiles').select('id, full_name'),
      ])
      setRequests(reqs)
      setActive(act)
      setNames(Object.fromEntries((profiles.data || []).map((p) => [p.id, p.full_name])))
    } catch {
      // Migration 028 not applied — hide rather than error.
      setUnavailable(true)
    }
  }, [memberId])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  if (unavailable || (requests.length === 0 && active.length === 0)) return null

  async function respond(id, accept) {
    setError('')
    setBusy(id)
    try {
      await respondToGuarantee(supabase, id, accept)
      await load()
      onChanged?.()
    } catch (err) {
      setError(err?.message || t('Could not save your answer.'))
    } finally {
      setBusy(null)
    }
  }

  return (
    <section className={CARD}>
      <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-3">
        {t('Loans you are backing')}
      </h2>

      {requests.length > 0 && (
        <ul className="divide-y divide-slate-100 mb-3">
          {requests.map((g) => (
            <li key={g.id} className="py-3 first:pt-0 space-y-2">
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <p className="text-sm font-medium text-slate-900">
                    {names[g.loans?.member_id] || t('A member')}
                  </p>
                  <p className="text-xs text-slate-500 mt-0.5">
                    {t('asked you to guarantee their {total} loan').replace(
                      '{total}',
                      formatTZS(g.loans?.principal ?? 0),
                    )}
                  </p>
                </div>
                <p className="text-sm font-semibold text-slate-900 tabular-nums shrink-0">
                  {formatTZS(g.pledged_amount)}
                </p>
              </div>

              <p className="text-xs px-3 py-2 rounded-lg bg-amber-50 ring-1 ring-inset ring-amber-200/70 text-amber-800">
                {t('If you accept, {amount} of your savings is locked until the loan is repaid — and the group can take it if the loan is never repaid.')
                  .replace('{amount}', formatTZS(g.pledged_amount))}
              </p>

              <div className="flex gap-2">
                <button
                  onClick={() => respond(g.id, true)}
                  disabled={busy === g.id}
                  className="btn-primary flex-1"
                >
                  {busy === g.id ? t('Working…') : t('Accept')}
                </button>
                <button
                  onClick={() => respond(g.id, false)}
                  disabled={busy === g.id}
                  className="btn-secondary flex-1"
                >
                  {t('Decline')}
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}

      {active.length > 0 && (
        <div className="rounded-xl bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 space-y-1">
          <p className="text-xs font-medium text-slate-700">{t('Currently guaranteeing')}</p>
          {active.map((g) => (
            <div key={g.id} className="flex justify-between text-sm">
              <span className="text-slate-500">
                {names[g.loans?.member_id] || t('A member')}
              </span>
              <span className="text-slate-900 tabular-nums">{formatTZS(g.pledged_amount)}</span>
            </div>
          ))}
          <p className="text-xs text-slate-500 pt-1">
            {t('This much of your savings is locked while these loans are open.')}
          </p>
        </div>
      )}

      {error && <p className="mt-2 text-sm text-red-600">{error}</p>}
    </section>
  )
}
