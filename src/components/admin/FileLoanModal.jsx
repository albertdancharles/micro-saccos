// Raise a loan on a member's behalf. Members no longer request loans — they ask
// an admin in person, and the admin files it here.
//
// This only creates the pending row. Disbursement is still approve_loan: 2-of-N,
// with the M-Pesa screenshot attached at the second signature, exactly as before.
//
// The ceiling shown here is advisory. approve_loan enforces both caps (a multiple
// of the member's contribution, and a fraction of TOTAL GROUP ASSETS since 045),
// plus the pool's ability to actually cover the disbursement, and file_loan
// enforces the three-loan limit. Nothing here is a guard; it just saves the admin
// filing something that will be refused later.
import { useCallback, useEffect, useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { useLanguage } from '../../hooks/useLanguage'
import { fileLoan, MAX_OPEN_LOANS, maxLoanFor } from '../../lib/loans'
import { monthlyInterest } from '../../lib/loanMath'
import { quarterEndAfter } from '../../lib/meetings'
import { formatDate, formatTZS } from '../../lib/format'

function Form({ members, onSubmitted, onClose }) {
  const { t } = useLanguage()
  const [memberId, setMemberId] = useState('')
  const [amount, setAmount] = useState('')
  const [limits, setLimits] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const loadLimits = useCallback(async () => {
    setLimits(null)
    if (!supabase || !memberId) return
    try {
      setLimits(await maxLoanFor(supabase, memberId))
    } catch {
      // Advisory only — a failure here must not stop the admin filing.
      setLimits(null)
    }
  }, [memberId])

  useEffect(() => {
    // load() sets a loading/reset flag synchronously before it awaits. That is
    // the one render the rule is warning about, and it is the intended one:
    // the panel must show its loading state the moment the input changes.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    loadLimits()
  }, [loadLimits])

  const over = limits && Number(amount) > limits.remaining
  // 045 split the ceiling from the cash: a loan can be well inside a member's
  // ceiling and still be more than the pool holds, because the ceiling is a
  // share of total assets and most of those may be out on loan. approve_loan
  // refuses that, so say so here rather than at the approval.
  const overPool = limits && !over && Number(amount) > Number(limits.pool)
  const hasOtherLoans = limits && limits.owed + limits.pending > 0
  const atLoanLimit = limits && limits.openLoans >= MAX_OPEN_LOANS

  // The terms this loan would get (051), so nobody is surprised by a short one. The
  // schedule itself is written by approve_loan.
  const term = quarterEndAfter()
  const interest = limits ? monthlyInterest(amount, limits.interestRate) : 0
  const termNote =
    term.months === 1
      ? t('Due {date}, with one interest payment of {amount}.')
      : t('Due {date}, with {n} monthly interest payments of {amount}.').replace('{n}', term.months)

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!memberId) return setError(t('Choose a member.'))
    if (!(Number(amount) > 0)) return setError(t('Enter an amount greater than zero.'))
    setBusy(true)
    try {
      await fileLoan(supabase, memberId, Number(amount))
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || t('Could not file the loan.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div>
        <label htmlFor="loan-member" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Member')}
        </label>
        <select
          id="loan-member"
          value={memberId}
          onChange={(e) => setMemberId(e.target.value)}
          className="input-field"
        >
          <option value="">{t('Choose a member…')}</option>
          {members.map((m) => (
            <option key={m.id} value={m.id} translate="no">
              {m.full_name}
            </option>
          ))}
        </select>
      </div>

      {limits && (
        <div className="rounded-xl bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 text-sm space-y-1">
          <div className="flex justify-between">
            <span className="text-slate-500">{t('Their savings')}</span>
            <span className="tabular-nums text-slate-900">
              {formatTZS(limits.contribution.total)}
            </span>
          </div>
          <div className="flex justify-between">
            <span className="text-slate-500">{t('Max eligible')}</span>
            <span className="tabular-nums text-slate-900">{formatTZS(limits.ceiling)}</span>
          </div>
          {hasOtherLoans && (
            <>
              <div className="flex justify-between">
                <span className="text-slate-500">{t('Already owes')}</span>
                <span className="tabular-nums text-slate-900">
                  {formatTZS(limits.owed + limits.pending)}
                </span>
              </div>
              <div className="flex justify-between font-medium">
                <span className="text-slate-700">{t('Can still borrow')}</span>
                <span className="tabular-nums text-slate-900">{formatTZS(limits.remaining)}</span>
              </div>
            </>
          )}
          <div className="flex justify-between">
            <span className="text-slate-500">{t('Cash in the pool')}</span>
            <span className="tabular-nums text-slate-900">{formatTZS(limits.pool)}</span>
          </div>
        </div>
      )}

      <div>
        <label htmlFor="loan-amount" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Loan amount (TSh)')}
        </label>
        <input
          id="loan-amount"
          type="number"
          min="0"
          inputMode="numeric"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          placeholder="0"
          className="input-field tabular-nums"
        />
        {atLoanLimit && (
          <p className="mt-1 text-xs text-red-600">
            {t('This member already has {n} loans in progress. One must be repaid or rejected first.').replace(
              '{n}',
              limits.openLoans,
            )}
          </p>
        )}
        {over && !atLoanLimit && (
          <p className="mt-1 text-xs text-red-600">
            {(hasOtherLoans
              ? t('Above the {amount} they can still borrow, counting their other loans — it may be refused at approval.')
              : t('Above the {amount} ceiling — the database will refuse to approve it.')
            ).replace('{amount}', formatTZS(limits.remaining))}
          </p>
        )}
        {overPool && (
          <p className="mt-1 text-xs text-amber-700">
            {t('Within their ceiling, but the pool only holds {amount} today — it cannot be disbursed until repayments come in.').replace(
              '{amount}',
              formatTZS(limits.pool),
            )}
          </p>
        )}
        {limits && Number(amount) > 0 && !over && !atLoanLimit && (
          <p className="mt-1 text-xs text-slate-500">
            {termNote
              .replace('{date}', formatDate(term.dueDate))
              .replace('{amount}', formatTZS(interest))}
          </p>
        )}
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="rounded-xl bg-amber-50 ring-1 ring-inset ring-amber-200/70 p-3 text-xs text-amber-800">
        {t('This only raises the request. Two admins must approve it, and the M-Pesa proof is attached at approval.')}
      </div>

      <div className="flex gap-2">
        <button type="submit" disabled={busy} className="btn-primary flex-1">
          {busy ? t('Filing…') : t('File loan')}
        </button>
        <button type="button" onClick={onClose} className="btn-secondary">
          {t('Cancel')}
        </button>
      </div>
    </form>
  )
}

export default function FileLoanModal({ open, onClose, members = [], onSubmitted }) {
  const { t } = useLanguage()
  return (
    <Modal open={open} onClose={onClose} title={t('File a loan')}>
      {open && <Form members={members} onSubmitted={onSubmitted} onClose={onClose} />}
    </Modal>
  )
}
