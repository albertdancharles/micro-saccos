// Member-facing withdrawal (migration 025). Shows what can actually be taken out
// right now and why the rest is held back, then opens a request.
//
// Two things constrain the figure and both are worth saying out loud: savings held
// as security behind an active loan, and the pool's own liquidity.
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../supabaseClient'
import { formatTZS, formatDate } from '../../lib/format'
import { getWithdrawable, getWithdrawals, requestWithdrawal } from '../../lib/withdrawals'
import Badge from '../ui/Badge'
import { useLanguage } from '../../hooks/useLanguage'

const CARD =
  'rounded-2xl border border-slate-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]'

export default function WithdrawalCard({ memberId, onSubmitted }) {
  const { t } = useLanguage()
  const [limits, setLimits] = useState(null)
  const [open, setOpen] = useState([])
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [unavailable, setUnavailable] = useState(false)

  const load = useCallback(async () => {
    if (!supabase || !memberId) return
    try {
      const [l, w] = await Promise.all([
        getWithdrawable(supabase, memberId),
        getWithdrawals(supabase, { memberId, openOnly: true }),
      ])
      setLimits(l)
      setOpen(w)
    } catch {
      // Migration 025 not applied yet — hide the card rather than show an error on
      // a dashboard where everything else works.
      setUnavailable(true)
    }
  }, [memberId])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  if (unavailable || !limits) return null

  const max = Number(limits.withdrawable_tzs)
  const locked = Number(limits.locked_tzs)
  const amountNum = Number(amount)
  const overMax = amountNum > max
  const pending = open[0] || null

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!(amountNum > 0)) return setError(t('Enter an amount greater than zero.'))
    if (overMax) {
      return setError(
        t('You can withdraw at most {amount} right now.').replace('{amount}', formatTZS(max)),
      )
    }
    if (!reason.trim()) return setError(t('A reason is required for every withdrawal.'))

    setBusy(true)
    try {
      await requestWithdrawal(supabase, amountNum, reason.trim())
      setAmount('')
      setReason('')
      await load()
      onSubmitted?.()
    } catch (err) {
      setError(err?.message || t('Could not submit your withdrawal request.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className={CARD}>
      <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-3">
        {t('Withdraw savings')}
      </h2>

      {pending ? (
        <div className="space-y-2">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-slate-900 tabular-nums">
                {formatTZS(pending.amount)}
              </p>
              <p className="text-xs text-slate-500 mt-0.5">
                {t('Requested {date}').replace(
                  '{date}',
                  formatDate(pending.created_at?.slice(0, 10)),
                )}
              </p>
            </div>
            <Badge status={pending.status === 'approved' ? 'approved' : 'pending'} />
          </div>
          <p className="text-xs text-slate-500">
            {pending.status === 'approved'
              ? t('Approved — the admins will pay this out and attach the proof.')
              : t('Two admins must approve before this can be paid out.')}
          </p>
        </div>
      ) : (
        <>
          <div className="rounded-xl bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 text-sm space-y-1 mb-3">
            <div className="flex justify-between">
              <span className="text-slate-500">{t('My savings')}</span>
              <span className="text-slate-900 tabular-nums">
                {formatTZS(limits.savings_tzs)}
              </span>
            </div>
            {locked > 0 && (
              <div className="flex justify-between">
                <span className="text-slate-500">{t('Held against your loan')}</span>
                <span className="text-red-700 tabular-nums">−{formatTZS(locked)}</span>
              </div>
            )}
            <div className="flex justify-between border-t border-slate-200 pt-1 mt-1">
              <span className="font-medium text-slate-700">{t('Available now')}</span>
              <span className="font-semibold text-slate-900 tabular-nums">{formatTZS(max)}</span>
            </div>
          </div>

          {max <= 0 ? (
            <p className="text-sm text-slate-500">
              {locked > 0
                ? t('Your savings are held as security while your loan is open.')
                : t('There is nothing available to withdraw right now.')}
            </p>
          ) : (
            <form onSubmit={handleSubmit} className="space-y-3">
              <input
                type="text"
                inputMode="decimal"
                value={amount}
                onChange={(e) => setAmount(e.target.value.replace(/[^\d.]/g, ''))}
                placeholder={t('Amount (TSh)')}
                aria-label={t('Amount (TSh)')}
                className="input-field tabular-nums"
              />
              <textarea
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                rows={2}
                placeholder={t('Why do you need to withdraw?')}
                aria-label={t('Reason')}
                className="input-field"
              />
              {error && <p className="text-sm text-red-600">{error}</p>}
              <button
                type="submit"
                disabled={busy || !(amountNum > 0) || overMax}
                className="btn-primary w-full"
              >
                {busy ? t('Submitting…') : t('Request withdrawal')}
              </button>
            </form>
          )}
        </>
      )}
    </section>
  )
}
