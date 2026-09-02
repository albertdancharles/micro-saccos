// Group accounts (migration 029) — the AGM pack.
//
// Three sections a co-operative needs and this app never had: what the group
// earned over a period, what it holds right now and whose it is, and one line per
// member. Exportable as a single CSV so it can be printed or circulated before the
// meeting.
import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../supabaseClient'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { formatTZS, formatDate } from '../lib/format'
import { downloadBlob } from '../lib/statements'
import { getOpenCycle } from '../lib/cycles'
import {
  getIncomeStatement,
  getBalanceSheet,
  getMemberReport,
  buildGroupReportCsv,
  defaultPeriod,
} from '../lib/reports'
import AppHeader from '../components/ui/AppHeader'
import BottomNav from '../components/ui/BottomNav'

const CARD =
  'rounded-2xl border border-slate-200/70 bg-white p-4 sm:p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]'

function Line({ label, value, tone, strong, indent }) {
  const color =
    tone === 'red' ? 'text-red-700' : tone === 'emerald' ? 'text-emerald-700' : 'text-slate-900'
  return (
    <div className={`flex justify-between text-sm ${indent ? 'pl-3' : ''}`}>
      <span className="text-slate-500">{label}</span>
      <span className={`tabular-nums ${color} ${strong ? 'font-semibold' : ''}`}>
        {formatTZS(value)}
      </span>
    </div>
  )
}

export default function Reports() {
  const { profile, user } = useAuth()
  const { t } = useLanguage()
  const [period, setPeriod] = useState(null)
  const [income, setIncome] = useState(null)
  const [balance, setBalance] = useState(null)
  const [members, setMembers] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    if (!supabase) return
    try {
      const cycle = await getOpenCycle(supabase).catch(() => null)
      const p = defaultPeriod(cycle)
      const [inc, bal, mem] = await Promise.all([
        getIncomeStatement(supabase, p.from, p.to),
        getBalanceSheet(supabase, null),
        getMemberReport(supabase, null),
      ])
      setPeriod(p)
      setIncome(inc)
      setBalance(bal)
      setMembers(mem)
      setError('')
    } catch (err) {
      setError(err?.message || t('Could not load the reports. Has migration 029 been applied?'))
    } finally {
      setLoading(false)
    }
  }, [t])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  function download() {
    downloadBlob(
      buildGroupReportCsv({ from: period.from, to: period.to, income, balance, members }),
      `micro-saccos-report-${period.to}.csv`,
    )
  }

  const balanced = balance && Number(balance.difference_tzs) === 0

  return (
    <div className="min-h-dvh bg-[var(--color-app-bg)]">
      <AppHeader
        eyebrow={t('Micro-SACCOS · Admin')}
        title={profile?.full_name || user?.email}
        width="max-w-4xl"
        links={[{ to: '/admin', label: t('← Admin') }]}
      />

      <main className="max-w-4xl mx-auto px-4 sm:px-6 py-5 sm:py-6 space-y-4 pb-nav">
        {error && (
          <div className="rounded-xl border border-red-200/70 bg-red-50 p-3 text-sm text-red-700">
            {error}
          </div>
        )}

        {loading ? (
          <p className="text-center text-slate-400 py-8">{t('Loading…')}</p>
        ) : (
          <>
            {/* ---------------------------------------------- income */}
            {income && period && (
              <section className={CARD}>
                <div className="flex items-baseline justify-between mb-3">
                  <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">
                    {t('What the group earned')}
                  </h2>
                  <span className="text-xs text-slate-400">
                    {formatDate(period.from)} – {formatDate(period.to)}
                  </span>
                </div>
                <div className="space-y-1">
                  <Line label={t('Interest on loans')} value={income.interest_tzs} tone="emerald" />
                  <Line label={t('Penalties collected')} value={income.penalty_tzs} tone="emerald" />
                  {Number(income.write_off_tzs) < 0 && (
                    <Line label={t('Written off')} value={income.write_off_tzs} tone="red" />
                  )}
                  <div className="border-t border-slate-200 my-1" />
                  <Line
                    label={t('Net earnings')}
                    value={income.net_tzs}
                    strong
                    tone={Number(income.net_tzs) >= 0 ? 'emerald' : 'red'}
                  />
                </div>
                <div className="mt-3 pt-3 border-t border-slate-100 space-y-1">
                  <div className="flex justify-between text-sm">
                    <span className="text-slate-500">{t('Loans issued')}</span>
                    <span className="tabular-nums text-slate-900">
                      {income.loans_issued} · {formatTZS(income.loans_issued_tzs)}
                    </span>
                  </div>
                  <Line label={t('Fee payments received')} value={income.fees_collected_tzs} />
                  <p className="text-xs text-slate-400 pt-1">
                    {t('Fee payments are members’ own capital, not profit — they are listed here for activity only.')}
                  </p>
                </div>
              </section>
            )}

            {/* ---------------------------------------------- balance sheet */}
            {balance && (
              <section className={CARD}>
                <div className="flex items-baseline justify-between mb-3">
                  <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">
                    {t('What the group holds')}
                  </h2>
                  <span className="text-xs text-slate-400">
                    {t('as at {date}').replace('{date}', formatDate(balance.as_of))}
                  </span>
                </div>

                <p className="text-[11px] font-semibold uppercase tracking-wide text-slate-400 mb-1">
                  {t('Assets')}
                </p>
                <div className="space-y-1">
                  <Line label={t('Cash in the pool')} value={balance.pool_tzs} indent />
                  <Line label={t('Out on loans')} value={balance.outstanding_tzs} indent />
                  <Line label={t('Total assets')} value={balance.total_assets_tzs} strong />
                </div>

                <p className="text-[11px] font-semibold uppercase tracking-wide text-slate-400 mt-3 mb-1">
                  {t('Whose it is')}
                </p>
                <div className="space-y-1">
                  <Line label={t('Member capital')} value={balance.member_capital_tzs} indent />
                  <Line label={t('Retained earnings')} value={balance.retained_earnings_tzs} indent />
                  <Line
                    label={t('Less: paid out')}
                    value={-Number(balance.distributions_paid_tzs)}
                    indent
                  />
                  <Line label={t('Total claims')} value={balance.total_claims_tzs} strong />
                </div>

                <p
                  className={`mt-3 text-xs px-3 py-2 rounded-lg ring-1 ring-inset ${
                    balanced
                      ? 'bg-emerald-50 ring-emerald-200/70 text-emerald-800'
                      : 'bg-red-50 ring-red-200/70 text-red-800'
                  }`}
                >
                  {balanced
                    ? t('Assets and claims agree — the books balance.')
                    : t('Off by {amount}. Resolve this before presenting these accounts.').replace(
                        '{amount}',
                        formatTZS(Math.abs(Number(balance.difference_tzs))),
                      )}
                </p>
              </section>
            )}

            {/* ---------------------------------------------- members */}
            {members.length > 0 && (
              <section className={CARD}>
                <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-3">
                  {t('Members ({n})').replace('{n}', members.length)}
                </h2>
                <div className="overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="text-slate-500 text-left">
                        <th className="py-1 pr-2 font-medium">{t('Member')}</th>
                        <th className="py-1 px-2 font-medium text-right">{t('Capital')}</th>
                        <th className="py-1 px-2 font-medium text-right">{t('Owes')}</th>
                        <th className="py-1 px-2 font-medium text-right">{t('Fines')}</th>
                        <th className="py-1 pl-2 font-medium text-right">{t('Last payout')}</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-100">
                      {members.map((m) => (
                        <tr key={m.member_id}>
                          <td className="py-1.5 pr-2 text-slate-700">{m.full_name}</td>
                          <td className="py-1.5 px-2 text-right tabular-nums text-slate-900">
                            {formatTZS(m.capital_tzs)}
                          </td>
                          <td className="py-1.5 px-2 text-right tabular-nums text-red-700">
                            {Number(m.outstanding_tzs) > 0 ? formatTZS(m.outstanding_tzs) : '—'}
                          </td>
                          <td className="py-1.5 px-2 text-right tabular-nums text-slate-500">
                            {Number(m.penalties_tzs) > 0 ? formatTZS(m.penalties_tzs) : '—'}
                          </td>
                          <td className="py-1.5 pl-2 text-right tabular-nums text-emerald-700">
                            {Number(m.last_payout_tzs) > 0 ? formatTZS(m.last_payout_tzs) : '—'}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </section>
            )}

            <button onClick={download} className="btn-primary w-full">
              {t('Download the report (CSV)')}
            </button>
            <Link to="/admin" className="btn-secondary w-full inline-flex justify-center">
              {t('← Admin')}
            </Link>
          </>
        )}
      </main>

      <BottomNav isAdmin />
    </div>
  )
}
