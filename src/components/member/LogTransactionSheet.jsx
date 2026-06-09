// Log a transaction (build plan §9). Bottom sheet: pick a type, (for fee/loan) the
// obligation being paid with a penalty-aware prefilled amount, upload the proof,
// and insert a pending payment_submission. The form is an inner component mounted
// only while open, so its state resets each time without a reset effect.
import { useMemo, useState } from 'react'
import Modal from '../ui/Modal'
import UploadZone from '../ui/UploadZone'
import { supabase } from '../../supabaseClient'
import { formatTZS, formatMonth, formatDate } from '../../lib/format'
import { buildProofPath, uploadPaymentProof } from '../../lib/storage'
import { submitPayment } from '../../lib/payments'

const TYPES = [
  { key: 'savings_deposit', label: 'Savings' },
  { key: 'monthly_fee', label: 'Monthly fee' },
  { key: 'loan_installment', label: 'Loan repayment' },
]

function TransactionForm({ memberId, unpaidFees, payableInstallments, onSubmitted, onClose }) {
  const [type, setType] = useState('savings_deposit')
  const [feeId, setFeeId] = useState('')
  const [instId, setInstId] = useState('')
  const [amount, setAmount] = useState('')
  const [file, setFile] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const selectedFee = useMemo(
    () => unpaidFees.find((f) => f.id === feeId) || null,
    [unpaidFees, feeId],
  )
  const selectedInst = useMemo(
    () => payableInstallments.find((i) => i.id === instId) || null,
    [payableInstallments, instId],
  )

  function chooseType(next) {
    setType(next)
    setFeeId('')
    setInstId('')
    setAmount('')
    setError('')
  }

  function chooseFee(id) {
    setFeeId(id)
    const f = unpaidFees.find((x) => x.id === id)
    setAmount(f ? String(f.total_with_penalty) : '')
  }

  function chooseInst(id) {
    setInstId(id)
    const i = payableInstallments.find((x) => x.id === id)
    setAmount(i ? String(i.total_with_penalty) : '')
  }

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    const amt = Number(amount)
    if (!(amt > 0)) return setError('Enter a valid amount.')
    if (!file) return setError('Upload a payment screenshot.')
    if (type === 'monthly_fee' && !selectedFee) return setError('Choose which fee you are paying.')
    if (type === 'loan_installment' && !selectedInst)
      return setError('Choose which installment you are paying.')

    setBusy(true)
    try {
      const path = buildProofPath({
        submissionType: type,
        memberId,
        file,
        period: selectedFee?.period,
        loanId: selectedInst?.loan_id,
        installmentNumber: selectedInst?.installment_number,
      })
      await uploadPaymentProof(supabase, file, path)
      await submitPayment(supabase, {
        memberId,
        submissionType: type,
        relatedId:
          type === 'monthly_fee'
            ? selectedFee.id
            : type === 'loan_installment'
              ? selectedInst.id
              : null,
        amountClaimed: amt,
        proofUrl: path,
      })
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || 'Could not submit. Please try again.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div className="grid grid-cols-3 gap-2">
        {TYPES.map((t) => (
          <button
            type="button"
            key={t.key}
            onClick={() => chooseType(t.key)}
            className={`rounded-xl border px-2 py-2.5 text-xs font-medium transition-all duration-150 ${
              type === t.key
                ? 'border-emerald-500 bg-emerald-50 text-emerald-700 ring-1 ring-emerald-200'
                : 'border-slate-200 text-slate-600 hover:border-slate-300'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {type === 'monthly_fee' && (
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">Which fee?</label>
          {unpaidFees.length ? (
            <select
              value={feeId}
              onChange={(e) => chooseFee(e.target.value)}
              className="input-field"
            >
              <option value="">Select a month…</option>
              {unpaidFees.map((f) => (
                <option key={f.id} value={f.id}>
                  {formatMonth(f.period)} — {formatTZS(f.total_with_penalty)}
                  {Number(f.penalty_due) > 0 ? ' (incl. penalty)' : ''}
                </option>
              ))}
            </select>
          ) : (
            <p className="text-sm text-slate-500">No outstanding fees.</p>
          )}
        </div>
      )}

      {type === 'loan_installment' && (
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">
            Which installment?
          </label>
          {payableInstallments.length ? (
            <select
              value={instId}
              onChange={(e) => chooseInst(e.target.value)}
              className="input-field"
            >
              <option value="">Select an installment…</option>
              {payableInstallments.map((i) => (
                <option key={i.id} value={i.id}>
                  #{i.installment_number} · due {formatDate(i.due_date)} —{' '}
                  {formatTZS(i.total_with_penalty)}
                  {Number(i.penalty_due) > 0 ? ' (incl. penalty)' : ''}
                </option>
              ))}
            </select>
          ) : (
            <p className="text-sm text-slate-500">No installments to pay.</p>
          )}
        </div>
      )}

      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">
          Amount paid (TSh)
        </label>
        <input
          type="number"
          min="0"
          inputMode="numeric"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          placeholder="Amount"
          className="input-field tabular-nums"
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">Payment proof</label>
        <UploadZone file={file} onSelect={setFile} />
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <button type="submit" disabled={busy} className="btn-primary w-full">
        {busy ? 'Submitting…' : 'Submit for approval'}
      </button>
    </form>
  )
}

export default function LogTransactionSheet({
  open,
  onClose,
  memberId,
  unpaidFees,
  payableInstallments,
  onSubmitted,
}) {
  return (
    <Modal open={open} onClose={onClose} title="Log a transaction">
      {open && (
        <TransactionForm
          memberId={memberId}
          unpaidFees={unpaidFees}
          payableInstallments={payableInstallments}
          onSubmitted={onSubmitted}
          onClose={onClose}
        />
      )}
    </Modal>
  )
}
