// Open a group-pool edit (admin-only). Adjusts the group pool (and thus total
// assets) by a positive or negative delta. The requester's vote does NOT
// auto-count; two OTHER admins must approve.
import { useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { requestPoolEdit } from '../../lib/admin'

function Form({ stats, onSubmitted, onClose }) {
  const [direction, setDirection] = useState('increase')
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const amountNum = Number(amount)
  const delta = direction === 'increase' ? amountNum : -amountNum
  const previewPool = Number(stats?.pool ?? 0) + delta
  const previewTotal = Number(stats?.totalAssets ?? stats?.pool ?? 0) + delta
  const wouldGoNegative = previewPool < 0

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!(amountNum > 0)) return setError('Enter an amount greater than zero.')
    if (!reason.trim()) return setError('A reason is required for every pool edit.')
    if (wouldGoNegative) {
      return setError(
        `This would leave the pool negative (${formatTZS(previewPool)}). Choose a smaller decrease.`,
      )
    }
    setBusy(true)
    try {
      await requestPoolEdit(supabase, delta, reason.trim())
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || 'Could not open the pool edit request.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div className="rounded-lg bg-gray-50 p-3 text-sm space-y-1">
        <div className="flex justify-between">
          <span className="text-gray-500">Current pool</span>
          <span className="text-gray-900">{formatTZS(stats?.pool ?? 0)}</span>
        </div>
        <div className="flex justify-between">
          <span className="text-gray-500">Current total assets</span>
          <span className="text-gray-900">
            {formatTZS(stats?.totalAssets ?? stats?.pool ?? 0)}
          </span>
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
          className="w-full rounded-lg border border-gray-300 px-3 py-2 text-gray-900 outline-none focus:border-sky-500 focus:ring-2 focus:ring-sky-200"
        />
        {amountNum > 0 && (
          <p className={`mt-1 text-xs ${wouldGoNegative ? 'text-red-600' : 'text-gray-500'}`}>
            After approval: pool {formatTZS(previewPool)} · total assets {formatTZS(previewTotal)}.
          </p>
        )}
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 mb-1">Reason</label>
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={2}
          placeholder="e.g. recorded interest from external account, or correction of a deposit mis-entry"
          className="w-full rounded-lg border border-gray-300 px-3 py-2 text-sm outline-none focus:border-sky-500"
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
          className="flex-1 rounded-lg bg-sky-600 text-white font-medium py-2.5 hover:bg-sky-700 disabled:opacity-50"
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

export default function RequestPoolEditModal({ open, onClose, stats, onSubmitted }) {
  return (
    <Modal open={open} onClose={onClose} title="Edit group total assets">
      {open && <Form stats={stats} onSubmitted={onSubmitted} onClose={onClose} />}
    </Modal>
  )
}
