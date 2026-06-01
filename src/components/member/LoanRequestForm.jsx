// Loan request (build plan §9, §8a). Shows the 5× ceiling and submits a pending
// request. Hidden when a loan is already in progress (Decision #4).
import { useState } from 'react'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { contributionCeiling, poolCeiling, maxLoan } from '../../lib/loanMath'
import { submitLoanRequest } from '../../lib/loans'

function Row({ label, value, strong }) {
  return (
    <div className="flex justify-between">
      <span className="text-gray-500">{label}</span>
      <span className={strong ? 'font-semibold text-gray-900' : 'text-gray-700'}>{value}</span>
    </div>
  )
}

export default function LoanRequestForm({ memberId, contribution, pool, loan, onSubmitted }) {
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
      <section className="rounded-2xl border border-gray-100 bg-white p-4">
        <h2 className="text-sm font-semibold text-gray-900 mb-1">Loan</h2>
        <p className="text-sm text-gray-500">
          {loan.status === 'pending'
            ? `Your request for ${formatTZS(loan.principal)} is awaiting admin approval.`
            : `You have an active loan of ${formatTZS(loan.principal)}. Repay it before requesting another.`}
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
      setError(err?.message || 'Could not submit your request.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="rounded-2xl border border-gray-100 bg-white p-4">
      <h2 className="text-sm font-semibold text-gray-900 mb-3">Request a loan</h2>

      <div className="rounded-lg bg-gray-50 p-3 text-sm mb-3 space-y-1">
        <Row label="3× your savings" value={formatTZS(contribCap)} />
        <Row label="25% of group pool" value={formatTZS(poolCap)} />
        <div className="border-t border-gray-200 my-1" />
        <Row label="Maximum you can request" value={formatTZS(eligible)} strong />
      </div>

      {eligible <= 0 ? (
        <p className="text-sm text-gray-500">
          {contribCap <= 0
            ? 'Make a savings deposit or pay your monthly fee to become eligible for a loan.'
            : 'The group pool is too low to issue a loan right now.'}
        </p>
      ) : (
        <form onSubmit={handleSubmit} className="space-y-3">
          <input
            type="number"
            min="0"
            inputMode="numeric"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="Amount (TSh)"
            className="w-full rounded-lg border border-gray-300 px-3 py-2 text-gray-900 focus:border-emerald-500 focus:ring-2 focus:ring-emerald-200 outline-none"
          />
          {amount !== '' && overLimit && (
            <p className="text-sm text-red-600">
              Exceeds the maximum of {formatTZS(eligible)} (
              {contribCap <= poolCap ? '3× your savings' : '25% of the group pool'}).
            </p>
          )}
          {error && <p className="text-sm text-red-600">{error}</p>}
          <button
            type="submit"
            disabled={busy || !(amountNum > 0) || overLimit}
            className="w-full rounded-lg bg-emerald-600 text-white font-medium py-2.5 hover:bg-emerald-700 disabled:opacity-50 transition-colors"
          >
            {busy ? 'Submitting…' : 'Submit request'}
          </button>
        </form>
      )}
    </section>
  )
}
