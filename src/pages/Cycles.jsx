// Cycles & share-out (migrations 023–024). The group's financial year: what this
// cycle has earned, what the split would look like, the 2-of-N vote to close, and
// the payout register afterwards.
//
// Nobody votes on a split they haven't seen — the preview is rendered from
// preview_cycle_close, which is the exact query close_cycle commits.
import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../supabaseClient'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { formatTZS, formatDate } from '../lib/format'
import { buildPayoutPath, uploadPaymentProof } from '../lib/storage'
import {
  getCycles,
  getCycleEarnings,
  previewCycleClose,
  getDistributions,
  getPendingClosures,
  requestCycleClose,
  approveCycleClose,
  cancelCycleClose,
  markDistributionPaid,
} from '../lib/cycles'
import AppHeader from '../components/ui/AppHeader'
import BottomNav from '../components/ui/BottomNav'
import UploadZone from '../components/ui/UploadZone'
import Badge from '../components/ui/Badge'

const CARD =
  'rounded-2xl border border-slate-200/70 bg-white p-4 sm:p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]'

function Row({ label, value, tone }) {
  const color =
    tone === 'red' ? 'text-red-700' : tone === 'emerald' ? 'text-emerald-700' : 'text-slate-900'
  return (
    <div className="flex justify-between text-sm">
      <span className="text-slate-500">{label}</span>
      <span className={`tabular-nums ${color}`}>{value}</span>
    </div>
  )
}

function EarningsCard({ cycle, earnings }) {
  const { t } = useLanguage()
  return (
    <section className={CARD}>
      <div className="flex items-baseline justify-between mb-1">
        <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">{cycle.name}</h2>
        <span className="text-xs text-slate-400">
          {formatDate(cycle.start_date)} – {formatDate(cycle.end_date)}
        </span>
      </div>
      <p className="text-xs text-slate-400 mb-3">
        {cycle.status === 'open' ? t('Open') : t('Closed')}
      </p>
      <div className="space-y-1">
        <Row label={t('Interest earned')} value={formatTZS(earnings.interest_tzs)} tone="emerald" />
        <Row label={t('Penalties collected')} value={formatTZS(earnings.penalty_tzs)} tone="emerald" />
        {Number(earnings.write_off_tzs) < 0 && (
          <Row label={t('Written off')} value={formatTZS(earnings.write_off_tzs)} tone="red" />
        )}
        <div className="border-t border-slate-200 my-1" />
        <Row
          label={t('Net earnings to share')}
          value={formatTZS(earnings.net_tzs)}
          tone={Number(earnings.net_tzs) >= 0 ? 'emerald' : 'red'}
        />
      </div>
    </section>
  )
}

function CloseWizard({ cycle, onDone }) {
  const { t } = useLanguage()
  const [mode, setMode] = useState('earnings_only')
  const [reason, setReason] = useState('')
  const [preview, setPreview] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  async function loadPreview(nextMode) {
    setError('')
    setBusy(true)
    try {
      setPreview(await previewCycleClose(supabase, cycle.id, nextMode))
    } catch (err) {
      setError(err?.message || t('Could not build the preview.'))
    } finally {
      setBusy(false)
    }
  }

  async function handleSubmit() {
    setError('')
    if (!reason.trim()) return setError(t('A reason is required to close a cycle.'))
    setBusy(true)
    try {
      await requestCycleClose(supabase, cycle.id, mode, reason.trim())
      onDone?.()
    } catch (err) {
      setError(err?.message || t('Could not open the closure request.'))
    } finally {
      setBusy(false)
    }
  }

  const total = (preview || []).reduce((s, r) => s + Number(r.total_payout_tzs), 0)

  return (
    <section className={CARD}>
      <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-3">
        {t('Close this cycle')}
      </h2>

      <div className="grid grid-cols-2 gap-2 mb-3">
        {[
          { key: 'earnings_only', label: t('Earnings only') },
          { key: 'full_shareout', label: t('Full share-out') },
        ].map((m) => (
          <button
            key={m.key}
            type="button"
            onClick={() => {
              setMode(m.key)
              setPreview(null)
            }}
            aria-pressed={mode === m.key}
            className={`segment border ${
              mode === m.key
                ? 'border-emerald-500 bg-emerald-50 text-emerald-700 ring-1 ring-emerald-200'
                : 'border-slate-200 text-slate-600 hover:border-slate-300'
            }`}
          >
            {m.label}
          </button>
        ))}
      </div>

      <p className="text-xs text-slate-500 mb-3">
        {mode === 'earnings_only'
          ? t('Profit is paid out; everyone’s savings roll into the next cycle.')
          : t('Profit AND savings go back to members. Every loan must be settled first.')}
      </p>

      <button onClick={() => loadPreview(mode)} disabled={busy} className="btn-secondary w-full mb-3">
        {busy ? t('Working…') : t('Preview the split')}
      </button>

      {preview && (
        <div className="rounded-xl bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 mb-3">
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead>
                <tr className="text-slate-500 text-left">
                  <th className="py-1 pr-2 font-medium">{t('Member')}</th>
                  <th className="py-1 px-2 font-medium text-right">{t('Share')}</th>
                  <th className="py-1 px-2 font-medium text-right">{t('Earnings')}</th>
                  {mode === 'full_shareout' && (
                    <th className="py-1 px-2 font-medium text-right">{t('Capital')}</th>
                  )}
                  <th className="py-1 pl-2 font-medium text-right">{t('Payout')}</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-200/70">
                {preview.map((r) => (
                  <tr key={r.member_id}>
                    <td className="py-1.5 pr-2 text-slate-700">{r.full_name}</td>
                    <td className="py-1.5 px-2 text-right tabular-nums text-slate-500">
                      {(Number(r.share_ratio) * 100).toFixed(1)}%
                    </td>
                    <td className="py-1.5 px-2 text-right tabular-nums text-emerald-700">
                      {formatTZS(r.earnings_tzs)}
                    </td>
                    {mode === 'full_shareout' && (
                      <td className="py-1.5 px-2 text-right tabular-nums text-slate-700">
                        {formatTZS(r.capital_returned_tzs)}
                      </td>
                    )}
                    <td className="py-1.5 pl-2 text-right tabular-nums font-medium text-slate-900">
                      {formatTZS(r.total_payout_tzs)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="mt-2 text-xs font-medium text-slate-700 text-right tabular-nums">
            {t('Total payout')}: {formatTZS(total)}
          </p>
          <p className="mt-2 text-[11px] text-slate-500">
            {t('Shares are weighted by how long each member’s money was in the group, not just their closing balance.')}
          </p>
        </div>
      )}

      <textarea
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        rows={2}
        placeholder={t('e.g. agreed at the annual general meeting on 12 December')}
        aria-label={t('Reason')}
        className="input-field mb-3"
      />

      {error && <p className="text-sm text-red-600 mb-3">{error}</p>}

      <div className="rounded-xl bg-amber-50 ring-1 ring-inset ring-amber-200/70 p-3 text-xs text-amber-800 mb-3">
        {t('Two other admins must approve. Closing freezes every figure above — later corrections cannot change an agreed share-out.')}
      </div>

      <button onClick={handleSubmit} disabled={busy || !preview} className="btn-primary w-full">
        {busy ? t('Submitting…') : t('Propose closing this cycle')}
      </button>
    </section>
  )
}

function ClosureVote({ closure, currentAdminId, onDone }) {
  const { t } = useLanguage()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const isRequester = closure.requested_by === currentAdminId

  async function run(fn) {
    setError('')
    setBusy(true)
    try {
      await fn()
      onDone?.()
    } catch (err) {
      setError(err?.message || t('Could not complete that.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="rounded-2xl border border-amber-200/70 bg-white p-4 sm:p-5">
      <h2 className="text-[13px] font-semibold tracking-tight text-amber-700 mb-2">
        {t('Cycle close awaiting approval')}
      </h2>
      <p className="text-sm text-slate-700">
        {closure.mode === 'full_shareout' ? t('Full share-out') : t('Earnings only')} ·{' '}
        {closure.reason}
      </p>
      {isRequester && (
        <p className="mt-2 text-xs px-3 py-2 rounded-lg bg-amber-50 ring-1 ring-inset ring-amber-200/70 text-amber-800">
          {t("You opened this request — you can't vote on it. Awaiting other admins.")}
        </p>
      )}
      {error && <p className="mt-2 text-sm text-red-600">{error}</p>}
      <div className="flex gap-2 mt-3">
        <button
          onClick={() => run(() => approveCycleClose(supabase, closure.id))}
          disabled={busy || isRequester}
          className="btn-primary flex-1"
        >
          {busy ? t('Working…') : t('Approve & close')}
        </button>
        <button
          onClick={() => run(() => cancelCycleClose(supabase, closure.id))}
          disabled={busy}
          className="btn-secondary"
        >
          {t('Cancel request')}
        </button>
      </div>
    </section>
  )
}

function PayoutRow({ dist, name, currentAdminId, onDone }) {
  const { t } = useLanguage()
  const [file, setFile] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [open, setOpen] = useState(false)

  const isPaid = dist.status === 'paid'
  const isSelf = dist.member_id === currentAdminId

  async function handlePay() {
    setError('')
    if (!file) return setError(t('Upload the payout screenshot.'))
    setBusy(true)
    try {
      const path = buildPayoutPath('share-out', dist.id, file)
      await uploadPaymentProof(supabase, file, path)
      await markDistributionPaid(supabase, dist.id, path)
      onDone?.()
    } catch (err) {
      setError(err?.message || t('Could not record the payout.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="py-3">
      <div className="flex items-center justify-between gap-3">
        <div className="min-w-0">
          <p className="text-sm font-medium text-slate-900 truncate">{name}</p>
          <p className="text-xs text-slate-500 mt-0.5 tabular-nums">
            {t('{earnings} earnings')
              .replace('{earnings}', formatTZS(dist.earnings_tzs))}
            {Number(dist.capital_returned_tzs) > 0 &&
              ` · ${t('{capital} capital').replace('{capital}', formatTZS(dist.capital_returned_tzs))}`}
          </p>
        </div>
        <div className="flex items-center gap-3 shrink-0">
          <p className="text-sm font-semibold text-slate-900 tabular-nums">
            {formatTZS(dist.total_payout_tzs)}
          </p>
          {isPaid ? (
            <Badge status="paid" />
          ) : (
            <button
              onClick={() => setOpen((v) => !v)}
              disabled={isSelf}
              className="btn-secondary text-xs px-3 py-1.5 disabled:opacity-40"
            >
              {t('Pay')}
            </button>
          )}
        </div>
      </div>

      {open && !isPaid && (
        <div className="mt-2 space-y-2">
          {isSelf && (
            <p className="text-xs text-amber-700">
              {t('Another admin must record your own payout.')}
            </p>
          )}
          <UploadZone file={file} onSelect={setFile} />
          {error && <p className="text-sm text-red-600">{error}</p>}
          <button onClick={handlePay} disabled={busy || isSelf} className="btn-primary w-full">
            {busy ? t('Working…') : t('Record payout')}
          </button>
        </div>
      )}
    </div>
  )
}

export default function Cycles() {
  const { profile, user } = useAuth()
  const { t } = useLanguage()
  const [cycles, setCycles] = useState([])
  const [earnings, setEarnings] = useState({})
  const [distributions, setDistributions] = useState([])
  const [closures, setClosures] = useState([])
  const [names, setNames] = useState({})
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    if (!supabase) return
    try {
      const [cs, ds, cl, profilesRes] = await Promise.all([
        getCycles(supabase),
        getDistributions(supabase),
        getPendingClosures(supabase),
        supabase.from('profiles').select('id, full_name'),
      ])
      const earningsByCycle = {}
      for (const c of cs) earningsByCycle[c.id] = await getCycleEarnings(supabase, c.id)
      setCycles(cs)
      setEarnings(earningsByCycle)
      setDistributions(ds)
      setClosures(cl)
      setNames(Object.fromEntries((profilesRes.data || []).map((p) => [p.id, p.full_name])))
      setError('')
    } catch (err) {
      setError(err?.message || t('Could not load cycles. Has migration 023 been applied?'))
    } finally {
      setLoading(false)
    }
  }, [t])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  const open = cycles.find((c) => c.status === 'open') || null
  const closed = cycles.filter((c) => c.status === 'closed')
  const openClosure = closures[0] || null

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
            {open && earnings[open.id] && (
              <EarningsCard cycle={open} earnings={earnings[open.id]} />
            )}

            {openClosure ? (
              <ClosureVote closure={openClosure} currentAdminId={user?.id} onDone={load} />
            ) : (
              open && <CloseWizard cycle={open} onDone={load} />
            )}

            {closed.map((c) => {
              const rows = distributions.filter((d) => d.cycle_id === c.id)
              const unpaid = rows.filter((d) => d.status !== 'paid').length
              return (
                <section key={c.id} className={CARD}>
                  <div className="flex items-baseline justify-between mb-1">
                    <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">
                      {c.name}
                    </h2>
                    <span className="text-xs text-slate-400">
                      {c.mode === 'full_shareout' ? t('Full share-out') : t('Earnings only')}
                    </span>
                  </div>
                  <p className="text-xs text-slate-400 mb-3">
                    {unpaid > 0
                      ? t('{n} payout(s) still to make').replace('{n}', unpaid)
                      : t('All payouts recorded')}
                  </p>
                  <div className="divide-y divide-slate-100">
                    {rows.map((d) => (
                      <PayoutRow
                        key={d.id}
                        dist={d}
                        name={names[d.member_id] || t('unknown')}
                        currentAdminId={user?.id}
                        onDone={load}
                      />
                    ))}
                  </div>
                </section>
              )
            })}

            {!open && !closed.length && (
              <p className="text-center text-slate-400 py-8">{t('No cycles yet.')}</p>
            )}

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
