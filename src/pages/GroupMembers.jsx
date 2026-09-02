// Group members directory (transparency). Every member can see every other
// member's savings and outstanding loan — the group runs on full mutual
// transparency. Data comes from the group_member_directory() RPC (migration 019),
// which exposes only these aggregate figures, never personal/contact details.
import { useEffect, useState } from 'react'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { supabase } from '../supabaseClient'
import { getMemberDirectory } from '../lib/directory'
import { formatTZS } from '../lib/format'
import AppHeader from '../components/ui/AppHeader'
import BottomNav from '../components/ui/BottomNav'

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
    <div className="min-h-dvh bg-[var(--color-app-bg)]">
      <AppHeader
        eyebrow={t('Micro-SACCOS')}
        title={t('Group members')}
        back={{ to: home, label: t('← Back') }}
      />

      <main className="max-w-md mx-auto px-4 sm:px-6 py-5 sm:py-6 space-y-4 pb-nav">
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
          <section className="rounded-2xl border border-slate-200/70 bg-white p-4 sm:p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
            <div className="flex items-baseline justify-between mb-3">
              <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">{t('Members')}</h2>
              <span className="text-xs text-slate-400 tabular-nums">
                {t('{n} total').replace('{n}', rows.length)}
              </span>
            </div>
            {/* A four-column table needed ~416px and so scrolled sideways on
                every phone — meaning the loan balance, the column people come
                here to compare, was the one always off-screen. Stacking each
                member into a row with both figures side by side fits 320px and
                keeps everything visible at once. */}
            <ul className="divide-y divide-slate-100">
              {rows.map((r) => {
                const isSelf = r.id === user?.id
                return (
                  <li
                    key={r.id}
                    className={`-mx-5 px-5 py-3 ${isSelf ? 'bg-emerald-50/50' : ''}`}
                  >
                    <div className="flex items-center gap-2">
                      <span className="truncate font-medium text-slate-900">{r.name}</span>
                      {isSelf && (
                        <span className="inline-flex shrink-0 items-center rounded-full bg-emerald-100 px-1.5 py-0.5 text-[10px] font-medium text-emerald-700 ring-1 ring-inset ring-emerald-200">
                          {t('You')}
                        </span>
                      )}
                      {r.role === 'admin' && (
                        <span className="inline-flex shrink-0 items-center rounded-full bg-slate-100 px-1.5 py-0.5 text-[10px] font-medium text-slate-600 ring-1 ring-inset ring-slate-200">
                          {t('admin')}
                        </span>
                      )}
                    </div>
                    <div className="mt-1.5 flex items-baseline gap-4">
                      <div className="min-w-0 flex-1">
                        <p className="text-[10px] font-medium uppercase tracking-wide text-slate-400">
                          {t('Savings')}
                        </p>
                        <p className="truncate text-sm text-slate-900 tabular-nums">
                          {formatTZS(r.savings)}
                        </p>
                      </div>
                      <div className="min-w-0 flex-1">
                        <p className="text-[10px] font-medium uppercase tracking-wide text-slate-400">
                          {t('Loan balance')}
                        </p>
                        <p className="truncate text-sm tabular-nums">
                          {r.hasActiveLoan ? (
                            <span className="text-amber-700">{formatTZS(r.loanBalance)}</span>
                          ) : (
                            <span className="text-slate-300">—</span>
                          )}
                        </p>
                      </div>
                    </div>
                  </li>
                )
              })}
            </ul>

            <div className="-mx-5 mt-1 border-t-2 border-slate-200 px-5 pt-3">
              <p className="text-[10px] font-medium uppercase tracking-wide text-slate-400">
                {t('total')}
              </p>
              <div className="mt-1 flex items-baseline gap-4 font-semibold text-slate-900">
                <p className="min-w-0 flex-1 truncate text-sm tabular-nums">
                  {formatTZS(totalSavings)}
                </p>
                <p className="min-w-0 flex-1 truncate text-sm tabular-nums">
                  {formatTZS(totalLoans)}
                </p>
              </div>
            </div>
          </section>
        )}
      </main>

      <BottomNav isAdmin={profile?.role === 'admin'} />
    </div>
  )
}
