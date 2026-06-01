// Open a savings-edit request for a member. Admins can target any non-admin
// member or themselves; the DB rejects requests against another admin. The
// requester's vote does NOT auto-count toward the threshold (the "other admins
// must approve" rule), so this opens at 0/N and waits for other admins.
import { useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { requestSavingsEdit } from '../../lib/admin'

function Form({ target, onSubmitted, onClose }) {
  const [direction, setDirection] = useState('increase')
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const amountNum = Number(amount)
  const delta = direction === 'increase' ? amountNum : -amountNum
  const previewSavings = (Number(target.savings) || 0) + delta
  const wouldGoNegative = previewSavings < 0

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!(amountNum > 0)) return setError('Enter an amount greater than zero.')
    if (!reason.trim()) return setError('A reason is required for every savings edit.')
    if (wouldGoNegative) {
      return setError(
        `This would leave ${target.name} with a negative balance (${formatTZS(previewSavings)}).`,
      )
    }
    setBusy(true)
    try {
      await requestSavingsEdit(supabase, target.id, delta, reason.trim())
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || 'Could not open the savings edit request.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div className="rounded-lg bg-gray-50 p-3 text-sm space-y-1">
        <div className="flex justify-between">
          <span className="text-gray-500">Member</span>
          <span className="text-gray-900">{target.name}</span>
        </div>
        <div className="flex justify-between">
          <span className="text-gray-500">Current savings</span>
          <span className="text-gray-900">{formatTZS(target.savings)}</span>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-2">
        <button
          type="button"
          onClick={() => setDirection('increase')}
          className={`rounded-lg border px-3 py-2 text-sm font-medium ${
            direction === 'increase'
              ? 'border-emerald-500 bg-emerald-50 text-emerald-700'
              : 'border-gray-200 text-gray-600'
          }`}
        >
          Increase
        </button>
        <button
          type="button"
          onClick={() => setDirection('decrease')}
          className={`rounded-lg border px-3 py-2 text-sm font-medium ${
            direction === 'decrease'
              ? 'border-red-500 bg-red-50 text-red-700'
              : 'border-gray-200 text-gray-600'
          }`}
        >
          Decrease
        </button>
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 mb-1">Amount (TSh)</label>
        <input
          type="number"
          min="0"
          inputMode="numeric"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          placeholder="0"
          className="w-full rounded-lg border border-gray-300 px-3 py-2 text-gray-900 outline-none focus:border-emerald-500 focus:ring-2 focus:ring-emerald-200"
        />
        {amountNum > 0 && (
          <p className={`mt-1 text-xs ${wouldGoNegative ? 'text-red-600' : 'text-gray-500'}`}>
            New savings would be {formatTZS(previewSavings)}.
          </p>
        )}
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 mb-1">Reason</label>
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={2}
          placeholder="e.g. correction of a missed deposit on 2026-04-15"
          className="w-full rounded-lg border border-gray-300 px-3 py-2 text-sm outline-none focus:border-emerald-500"
        />
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-800">
        Two <strong>other</strong> admins must approve this edit before it applies. You can't
        approve your own request.
      </div>

      <div className="flex gap-2">
        <button
          type="submit"
          disabled={busy}
          className="flex-1 rounded-lg bg-emerald-600 text-white font-medium py-2.5 hover:bg-emerald-700 disabled:opacity-50"
        >
          {busy ? 'Submitting…' : 'Submit edit'}
        </button>
        <button
          type="button"
          onClick={onClose}
          className="rounded-lg border border-gray-300 px-4 py-2.5 text-gray-600"
        >
          Cancel
        </button>
      </div>
    </form>
  )
}

export default function RequestSavingsEditModal({ open, onClose, target, onSubmitted }) {
  return (
    <Modal open={open} onClose={onClose} title="Edit member savings">
      {open && target && <Form target={target} onSubmitted={onSubmitted} onClose={onClose} />}
    </Modal>
  )
}
