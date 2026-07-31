// Open a distress action against an active loan (admin-only, migration 022).
// The requester's vote does NOT auto-count, and no admin can action their own loan.
import { useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { requestLoanAction } from '../../lib/loanActions'
import { useLanguage } from '../../hooks/useLanguage'
import { useGroupSettings } from '../../hooks/useGroupSettings'

function Row({ label, value, danger }) {
  return (
    <div className="flex justify-between text-sm">
      <span className="text-slate-500">{label}</span>
      <span className={`tabular-nums ${danger ? 'font-semibold text-red-700' : 'text-slate-900'}`}>
        {value}
      </span>
    </div>
  )
}

function Form({ loan, onSubmitted, onClose }) {
  const { t } = useLanguage()
  const { settings } = useGroupSettings()
  const [action, setAction] = useState('restructure')
  const [termMonths, setTermMonths] = useState(String(settings.default_loan_months ?? 3))
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const outstanding = Number(loan?.outstanding ?? 0)
  const savings = Number(loan?.memberSavings ?? 0)
  const amountNum = Number(amount)
  // The RPC clamps to min(requested, outstanding, savings); previewing the same
  // number here stops an admin proposing a figure the DB will silently reduce.
  const recoverable = Math.min(outstanding, savings)

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!reason.trim()) return setError(t('A reason is required for every loan action.'))

    if (action === 'restructure') {
      const n = Number(termMonths)
      if (!(n >= 1 && n <= 24)) return setError(t('Term must be between 1 and 24 months.'))
    }
    if (action === 'recover_from_savings') {
      if (!(amountNum > 0)) return setError(t('Enter an amount greater than zero.'))
      if (recoverable <= 0) return setError(t('This member has no savings to recover from.'))
      if (amountNum > recoverable) {
        return setError(
          t('At most {amount} can be recovered (the lower of the balance owed and their savings).')
            .replace('{amount}', formatTZS(recoverable)),
        )
      }
    }

    setBusy(true)
    try {
      await requestLoanAction(supabase, loan.id, action, reason.trim(), {
        amount: action === 'recover_from_savings' ? amountNum : null,
        termMonths: action === 'restructure' ? Number(termMonths) : null,
      })
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || t('Could not open the loan action request.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div className="rounded-xl bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 space-y-1">
        <Row label={t('Borrower')} value={loan.memberName} />
        <Row label={t('Outstanding')} value={formatTZS(outstanding)} danger />
        <Row label={t('Their savings')} value={formatTZS(savings)} />
        {loan.risk && (
          <Row
            label={t('Overdue installments')}
            value={loan.risk.overdue_installments}
            danger
          />
        )}
      </div>

      <div>
        <label htmlFor="loan-action" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Action')}
        </label>
        <select
          id="loan-action"
          value={action}
          onChange={(e) => {
            setAction(e.target.value)
            setError('')
          }}
          className="input-field"
        >
          <option value="restructure">{t('Reschedule the loan')}</option>
          <option value="recover_from_savings">{t('Recover from their savings')}</option>
          <option value="write_off">{t('Write off the balance')}</option>
        </select>
      </div>

      {action === 'restructure' && (
        <div>
          <label htmlFor="loan-term" className="block text-sm font-medium text-slate-700 mb-1">
            {t('New term (months)')}
          </label>
          <input
            id="loan-term"
            type="number"
            min="1"
            max="24"
            inputMode="numeric"
            value={termMonths}
            onChange={(e) => setTermMonths(e.target.value)}
            className="input-field tabular-nums"
          />
          <p className="mt-1 text-xs text-slate-500">
            {t('A new schedule is cut over {n} month(s) on the {amount} still outstanding. Unpaid installments are cancelled, which also cancels the penalty they had accrued.')
              .replace('{n}', termMonths || '—')
              .replace('{amount}', formatTZS(outstanding))}
          </p>
        </div>
      )}

      {action === 'recover_from_savings' && (
        <div>
          <label htmlFor="recover-amount" className="block text-sm font-medium text-slate-700 mb-1">
            {t('Amount (TSh)')}
          </label>
          <input
            id="recover-amount"
            type="number"
            min="0"
            inputMode="numeric"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="0"
            className="input-field tabular-nums"
          />
          <p className="mt-1 text-xs text-slate-500">
            {t('Up to {amount}. Their savings drop by this amount and the loan balance falls with it — no cash moves.')
              .replace('{amount}', formatTZS(recoverable))}
          </p>
        </div>
      )}

      {action === 'write_off' && (
        <p className="rounded-xl bg-red-50 ring-1 ring-inset ring-red-200/70 p-3 text-xs text-red-800">
          {t('The group permanently absorbs the {amount} still owed. The pool falls by that amount and the debt is closed.')
            .replace('{amount}', formatTZS(outstanding))}
        </p>
      )}

      <div>
        <label htmlFor="loan-action-reason" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Reason')}
        </label>
        <textarea
          id="loan-action-reason"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={2}
          placeholder={t('e.g. lost their job in March; agreed a longer repayment at the April meeting')}
          className="input-field"
        />
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="rounded-xl bg-amber-50 ring-1 ring-inset ring-amber-200/70 p-3 text-xs text-amber-800">
        {t("Two other admins must approve this action before it applies. You can't approve your own request.")}
      </div>

      <div className="flex gap-2">
        <button type="submit" disabled={busy} className="btn-info flex-1">
          {busy ? t('Submitting…') : t('Submit action')}
        </button>
        <button type="button" onClick={onClose} className="btn-secondary">
          {t('Cancel')}
        </button>
      </div>
    </form>
  )
}

export default function RequestLoanActionModal({ open, loan, onClose, onSubmitted }) {
  const { t } = useLanguage()
  return (
    <Modal open={open} onClose={onClose} title={t('Loan action')}>
      {open && loan && <Form loan={loan} onSubmitted={onSubmitted} onClose={onClose} />}
    </Modal>
  )
}
