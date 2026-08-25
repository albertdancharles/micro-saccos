// The monthly fee sheet — the screen that replaced fifteen member submissions.
//
// Under the admin mandate every payment is keyed by an admin, and monthly fees are
// the bulk of that: one fixed amount per member, every month, against rows the
// system generated itself. Keying them one at a time through the single-payment
// form would be ~15 modal round-trips a month, so this is a sheet: tick who paid,
// correct any amount that differs, post once.
//
// Fees post on ONE signature (the group's decision — a fixed amount against a
// system-generated row has nothing to second-guess). Everything else needs two.
//
// The admin's OWN fee is deliberately excluded from the sheet and shown separately:
// record_fee_payments rejects it server-side, because an admin's own money always
// needs a second admin. The row is here so it does not look like an omission.
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../supabaseClient'
import { useAuth } from '../../hooks/useAuth'
import { useLanguage } from '../../hooks/useLanguage'
import { recordFeePayments } from '../../lib/payments'
import { formatTZS, formatDate } from '../../lib/format'

export default function RecordFeeSheet({ onActioned }) {
  const { user } = useAuth()
  const { t } = useLanguage()
  const [rows, setRows] = useState([])
  const [ticked, setTicked] = useState({}) // feeId -> amount string
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [open, setOpen] = useState(false)

  const load = useCallback(async () => {
    if (!supabase) return
    setLoading(true)
    try {
      const [feeRes, profRes] = await Promise.all([
        supabase
          .from('v_fee_status_money')
          .select('*')
          .neq('status', 'paid')
          .order('period', { ascending: true }),
        supabase.from('profiles').select('id, full_name').eq('is_active', true),
      ])
      if (feeRes.error) throw feeRes.error
      if (profRes.error) throw profRes.error
      const nameOf = Object.fromEntries(profRes.data.map((p) => [p.id, p.full_name]))
      setRows(
        feeRes.data.map((f) => ({
          ...f,
          name: nameOf[f.member_id] || 'Unknown',
          // What is still owed, penalty included — the figure the admin will
          // usually be confirming.
          outstanding: Math.max(Number(f.total_with_penalty) - Number(f.amount_paid || 0), 0),
        })),
      )
    } catch (err) {
      setError(err?.message || t('Could not load the fee sheet.'))
    } finally {
      setLoading(false)
    }
  }, [t])

  useEffect(() => {
    // load() sets a loading/reset flag synchronously before it awaits. That is
    // the one render the rule is warning about, and it is the intended one:
    // the panel must show its loading state the moment the input changes.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (open) load()
  }, [open, load])

  const mine = rows.filter((r) => r.member_id === user?.id)
  const others = rows.filter((r) => r.member_id !== user?.id)
  const selected = others.filter((r) => ticked[r.id] !== undefined)
  const total = selected.reduce((s, r) => s + (Number(ticked[r.id]) || 0), 0)

  function toggle(row) {
    setTicked((prev) => {
      const next = { ...prev }
      if (next[row.id] !== undefined) delete next[row.id]
      else next[row.id] = String(row.outstanding)
      return next
    })
  }

  async function handlePost() {
    setError('')
    if (selected.length === 0) return setError(t('Tick at least one member.'))
    if (selected.some((r) => !(Number(ticked[r.id]) > 0))) {
      return setError(t('Every ticked member needs an amount greater than zero.'))
    }
    setBusy(true)
    try {
      await recordFeePayments(
        supabase,
        selected.map((r) => ({ fee_id: r.id, amount: Number(ticked[r.id]) })),
      )
      setTicked({})
      await load()
      onActioned?.()
    } catch (err) {
      // The batch is all-or-nothing server-side, so nothing posted.
      setError(err?.message || t('Could not post the fee sheet.'))
    } finally {
      setBusy(false)
    }
  }

  if (!open) {
    return (
      <button
        onClick={() => setOpen(true)}
        className="btn-primary w-full !min-h-12"
      >
        {t('Record monthly fees')}
      </button>
    )
  }

  return (
    <section className="card space-y-3">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold text-slate-900">{t('Record monthly fees')}</h2>
        <button onClick={() => setOpen(false)} className="text-sm text-slate-500 hover:text-slate-700">
          {t('Close')}
        </button>
      </div>

      {loading ? (
        <div className="skeleton h-24 w-full" />
      ) : others.length === 0 ? (
        <p className="text-sm text-slate-500 py-4 text-center">
          {t('Every fee is settled. Nothing to record.')}
        </p>
      ) : (
        <>
          <div className="divide-y divide-slate-100">
            {others.map((r) => {
              const on = ticked[r.id] !== undefined
              return (
                <div key={r.id} className="flex items-center gap-3 py-2">
                  <input
                    type="checkbox"
                    checked={on}
                    onChange={() => toggle(r)}
                    aria-label={t('Record fee for {name}').replace('{name}', r.name)}
                    className="size-5 shrink-0 rounded border-slate-300 text-emerald-600 focus:ring-emerald-500"
                  />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm text-slate-900">{r.name}</p>
                    <p className="text-xs text-slate-500">
                      {formatDate(r.period)}
                      {Number(r.penalty_due) > 0 && (
                        <span className="text-amber-700">
                          {' · '}
                          {t('penalty {amount}').replace('{amount}', formatTZS(r.penalty_due))}
                        </span>
                      )}
                    </p>
                  </div>
                  <input
                    type="number"
                    min="0"
                    inputMode="numeric"
                    disabled={!on}
                    value={on ? ticked[r.id] : r.outstanding}
                    onChange={(e) =>
                      setTicked((prev) => ({ ...prev, [r.id]: e.target.value }))
                    }
                    aria-label={t('Amount for {name}').replace('{name}', r.name)}
                    className="input-field w-28 shrink-0 tabular-nums text-right disabled:bg-slate-50 disabled:text-slate-400"
                  />
                </div>
              )
            })}
          </div>

          {mine.length > 0 && (
            <p className="rounded-xl bg-amber-50 ring-1 ring-inset ring-amber-200/70 p-3 text-xs text-amber-800">
              {t('Your own fee is not on this sheet. Record it with “Record a payment” — an admin’s own money always needs a second admin’s signature.')}
            </p>
          )}

          {error && <p className="text-sm text-red-600">{error}</p>}

          <div className="flex items-center justify-between gap-3 pt-1">
            <p className="text-sm text-slate-600 tabular-nums">
              {t('{n} selected · {amount}')
                .replace('{n}', selected.length)
                .replace('{amount}', formatTZS(total))}
            </p>
            <button
              onClick={handlePost}
              disabled={busy || selected.length === 0}
              className="btn-primary"
            >
              {busy
                ? t('Posting…')
                : t('Post {n} payments').replace('{n}', selected.length)}
            </button>
          </div>
        </>
      )}
    </section>
  )
}
