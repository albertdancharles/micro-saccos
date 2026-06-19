// Loan request (build plan §9, §8a). Shows the 5× ceiling and submits a pending
// request. Hidden when a loan is already in progress (Decision #4).
import { useState } from 'react'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { contributionCeiling, poolCeiling, maxLoan } from '../../lib/loanMath'
import { submitLoanRequest } from '../../lib/loans'
import { useLanguage } from '../../hooks/useLanguage'

function Row({ label, value, strong }) {
  return (
    <div className="flex justify-between">
      <span className="text-slate-500">{label}</span>
      <span
        className={`tabular-nums ${strong ? 'font-semibold text-slate-900' : 'text-slate-700'}`}
      >
        {value}
      </span>
    </div>
  )
}

const CARD =
  'rounded-2xl border border-slate-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]'

export default function LoanRequestForm({ memberId, contribution, pool, loan, onSubmitted }) {
  const { t } = useLanguage()
  const [amount, setAmount] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const contribCap = contributionCeiling(contribution)
  const poolCap = poolCeiling(pool)
  const eligible = maxLoan(contribution, pool)
  const amountNum = Number(amount)
  const overLimit = amountNum > eligible

  if (loan) {
    return (
      <section className={CARD}>
        <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-1">{t('Loan')}</h2>
        <p className="text-sm text-slate-500">
          {loan.status === 'pending'
            ? t('Your request for {amount} is awaiting admin approval.').replace('{amount}', formatTZS(loan.principal))
            : t('You have an active loan of {amount}. Repay it before requesting another.').replace('{amount}', formatTZS(loan.principal))}
        </p>
      </section>
    )
  }

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    setBusy(true)
    try {
      await submitLoanRequest(supabase, memberId, amountNum)
      setAmount('')
      onSubmitted?.()
    } catch (err) {
      setError(err?.message || t('Could not submit your request.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className={CARD}>
      <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-3">
        {t('Request a loan')}
      </h2>

      <div className="rounded-xl bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 text-sm mb-3 space-y-1">
        <Row label={t('5× your savings')} value={formatTZS(contribCap)} />
        <Row label={t('25% of group pool')} value={formatTZS(poolCap)} />
        <div className="border-t border-slate-200 my-1" />
        <Row label={t('Maximum you can request')} value={formatTZS(eligible)} strong />
      </div>

      {eligible <= 0 ? (
        <p className="text-sm text-slate-500">
          {contribCap <= 0
            ? t('Make a savings deposit or pay your monthly fee to become eligible for a loan.')
            : t('The group pool is too low to issue a loan right now.')}
        </p>
      ) : (
        <form onSubmit={handleSubmit} className="space-y-3">
          <input
            type="number"
            min="0"
            inputMode="numeric"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder={t('Amount (TSh)')}
            className="input-field tabular-nums"
          />
          {amount !== '' && overLimit && (
            <p className="text-sm text-red-600">
              {t('Exceeds the maximum of {amount} ({limit}).')
                .replace('{amount}', formatTZS(eligible))
                .replace('{limit}', contribCap <= poolCap ? t('5× your savings') : t('25% of the group pool'))}
            </p>
          )}
          {error && <p className="text-sm text-red-600">{error}</p>}
          <button
            type="submit"
            disabled={busy || !(amountNum > 0) || overLimit}
            className="btn-primary w-full"
          >
            {busy ? t('Submitting…') : t('Submit request')}
          </button>
        </form>
      )}
    </section>
  )
}
