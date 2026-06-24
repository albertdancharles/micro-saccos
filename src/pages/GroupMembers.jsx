// Group members directory (transparency). Every member can see every other
// member's savings and outstanding loan — the group runs on full mutual
// transparency. Data comes from the group_member_directory() RPC (migration 019),
// which exposes only these aggregate figures, never personal/contact details.
import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { supabase } from '../supabaseClient'
import { getMemberDirectory } from '../lib/directory'
import { formatTZS } from '../lib/format'

export default function GroupMembers() {
  const { user, profile } = useAuth()
  const { t } = useLanguage()
  const home = profile?.role === 'admin' ? '/admin' : '/dashboard'
  const [rows, setRows] = useState(null)
  const [error, setError] = useState('')

  useEffect(() => {
    if (!supabase) return
    let cancelled = false
    getMemberDirectory(supabase)
      .then((data) => {
        if (!cancelled) setRows(data)
      })
      .catch((e) => {
        if (!cancelled) setError(e?.message || t('Could not load members.'))
      })
    return () => {
      cancelled = true
    }
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  const totalSavings = (rows || []).reduce((s, r) => s + r.savings, 0)
  const totalLoans = (rows || []).reduce((s, r) => s + r.loanBalance, 0)

  return (
    <div className="min-h-screen bg-[var(--color-app-bg)]">
      <header className="bg-white/85 backdrop-blur-md border-b border-slate-200/70 sticky top-0 z-10">
        <div className="max-w-md mx-auto px-6 py-4 flex items-center justify-between gap-3">
          <div className="min-w-0">
            <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-emerald-600">
              {t('Micro-SACCOS')}
            </p>
            <h1 className="text-base font-semibold tracking-tight text-slate-900 truncate">
              {t('Group members')}
            </h1>
          </div>
          <Link
            to={home}
            className="text-sm font-medium text-slate-500 hover:text-slate-800 shrink-0"
          >
            {t('← Back')}
          </Link>
        </div>
      </header>

      <main className="max-w-md mx-auto px-6 py-6 space-y-4">
        <p className="text-sm text-slate-500">
          {t('Every member can see every member’s savings and loans. Full transparency keeps the group accountable.')}
        </p>

        {error && (
          <div className="rounded-xl border border-red-200/70 bg-red-50 p-3 text-sm text-red-700">
            {error}
          </div>
        )}

        {rows == null && !error ? (
          <p className="text-center text-slate-400 py-8">{t('Loading…')}</p>
        ) : rows && (
          <section className="rounded-2xl border border-slate-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
            <div className="flex items-baseline justify-between mb-3">
              <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">{t('Members')}</h2>
              <span className="text-xs text-slate-400 tabular-nums">
                {t('{n} total').replace('{n}', rows.length)}
              </span>
            </div>
            <div className="overflow-x-auto -mx-5 px-5">
              <table className="w-full text-sm min-w-[26rem]">
                <thead>
                  <tr className="text-left text-[11px] uppercase tracking-wide text-slate-400">
                    <th className="py-2 pr-3 font-semibold">#</th>
                    <th className="py-2 pr-3 font-semibold">{t('Member')}</th>
                    <th className="py-2 pr-3 font-semibold text-right">{t('Savings')}</th>
                    <th className="py-2 font-semibold text-right">{t('Loan balance')}</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r, idx) => {
                    const isSelf = r.id === user?.id
                    return (
                      <tr
                        key={r.id}
                        className={`border-t border-slate-100 ${isSelf ? 'bg-emerald-50/50' : 'hover:bg-slate-50/70'}`}
                      >
                        <td className="py-3 pr-3 text-slate-400 tabular-nums">{idx + 1}</td>
                        <td className="py-3 pr-3 whitespace-nowrap">
                          <span className="font-medium text-slate-900">{r.name}</span>
                          {isSelf && (
                            <span className="ml-1.5 inline-flex items-center rounded-full bg-emerald-100 px-1.5 py-0.5 text-[10px] font-medium text-emerald-700 ring-1 ring-inset ring-emerald-200">
                              {t('You')}
                            </span>
                          )}
                          {r.role === 'admin' && (
                            <span className="ml-1.5 inline-flex items-center rounded-full bg-slate-100 px-1.5 py-0.5 text-[10px] font-medium text-slate-600 ring-1 ring-inset ring-slate-200">
                              {t('admin')}
                            </span>
                          )}
                        </td>
                        <td className="py-3 pr-3 text-right text-slate-900 tabular-nums">
                          {formatTZS(r.savings)}
                        </td>
                        <td className="py-3 text-right tabular-nums">
                          {r.hasActiveLoan ? (
                            <span className="text-amber-700">{formatTZS(r.loanBalance)}</span>
                          ) : (
                            <span className="text-slate-300">—</span>
                          )}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
                <tfoot>
                  <tr className="border-t-2 border-slate-200 font-semibold text-slate-900">
                    <td className="py-3 pr-3" />
                    <td className="py-3 pr-3 text-[11px] uppercase tracking-wide text-slate-400">
                      {t('total')}
                    </td>
                    <td className="py-3 pr-3 text-right tabular-nums">{formatTZS(totalSavings)}</td>
                    <td className="py-3 text-right tabular-nums">{formatTZS(totalLoans)}</td>
                  </tr>
                </tfoot>
              </table>
            </div>
          </section>
        )}
      </main>
    </div>
  )
}
