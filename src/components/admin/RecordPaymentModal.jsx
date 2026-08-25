// Record one payment for a member — savings deposit, a single monthly fee, or a
// loan repayment. The fee sheet handles the monthly bulk; this is for everything
// that varies, and for the admin's own money.
//
// How many signatures it needs depends on what is being recorded, so the modal says
// which case applies BEFORE the admin commits. The rule lives in SQL
// (submission_threshold); this only mirrors it for the message.
import { useCallback, useEffect, useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { useAuth } from '../../hooks/useAuth'
import { useLanguage } from '../../hooks/useLanguage'
import { recordPayment } from '../../lib/payments'
import { formatTZS, formatDate } from '../../lib/format'

const TYPES = [
  { value: 'savings_deposit', label: 'Savings deposit' },
  { value: 'monthly_fee', label: 'Monthly fee' },
  { value: 'loan_installment', label: 'Loan repayment' },
]

function Form({ members, onSubmitted, onClose }) {
  const { user } = useAuth()
  const { t } = useLanguage()
  const [memberId, setMemberId] = useState('')
  const [type, setType] = useState('savings_deposit')
  const [relatedId, setRelatedId] = useState('')
  const [amount, setAmount] = useState('')
  const [options, setOptions] = useState([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const isSelf = memberId && memberId === user?.id
  const needsTwo = isSelf || type !== 'monthly_fee'

  // What this member can actually pay against, for the two types that settle a
  // specific row. Refetched whenever the member or type changes so the picker can
  // never offer a row belonging to somebody else.
  const loadOptions = useCallback(async () => {
    setOptions([])
    setRelatedId('')
    if (!supabase || !memberId || type === 'savings_deposit') return
    try {
      if (type === 'monthly_fee') {
        const { data, error: err } = await supabase
          .from('v_fee_status_money')
          .select('*')
          .eq('member_id', memberId)
          .neq('status', 'paid')
          .order('period', { ascending: true })
        if (err) throw err
        setOptions(
          data.map((f) => ({
            id: f.id,
            label: `${formatDate(f.period)} — ${formatTZS(
              Math.max(Number(f.total_with_penalty) - Number(f.amount_paid || 0), 0),
            )}`,
            suggested: Math.max(Number(f.total_with_penalty) - Number(f.amount_paid || 0), 0),
          })),
        )
      } else {
        const { data: loans, error: le } = await supabase
          .from('loans')
          .select('id')
          .eq('member_id', memberId)
          .eq('status', 'active')
        if (le) throw le
        if (!loans.length) return
        const { data, error: ie } = await supabase
          .from('v_installment_status_money')
          .select('*')
          .in('loan_id', loans.map((l) => l.id))
          .not('status', 'in', '("paid","cancelled")')
          .order('installment_number', { ascending: true })
        if (ie) throw ie
        setOptions(
          data.map((i) => ({
            id: i.id,
            label: `#${i.installment_number} — ${formatDate(i.due_date)} — ${formatTZS(
              i.total_with_penalty,
            )}`,
            suggested: Number(i.total_with_penalty),
          })),
        )
      }
    } catch (err) {
      setError(err?.message || t('Could not load what this member owes.'))
    }
  }, [memberId, type, t])

  useEffect(() => {
    // load() sets a loading/reset flag synchronously before it awaits. That is
    // the one render the rule is warning about, and it is the intended one:
    // the panel must show its loading state the moment the input changes.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    loadOptions()
  }, [loadOptions])

  function pickRelated(id) {
    setRelatedId(id)
    const hit = options.find((o) => o.id === id)
    if (hit && !amount) setAmount(String(hit.suggested))
  }

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!memberId) return setError(t('Choose a member.'))
    if (!(Number(amount) > 0)) return setError(t('Enter an amount greater than zero.'))
    if (type !== 'savings_deposit' && !relatedId) {
      return setError(t('Choose which fee or installment this payment settles.'))
    }
    setBusy(true)
    try {
      await recordPayment(supabase, {
        memberId,
        submissionType: type,
        relatedId: type === 'savings_deposit' ? null : relatedId,
        amount: Number(amount),
      })
      onSubmitted?.()
      onClose()
    } catch (err) {
      setError(err?.message || t('Could not record the payment.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div>
        <label htmlFor="rec-member" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Member')}
        </label>
        <select
          id="rec-member"
          value={memberId}
          onChange={(e) => setMemberId(e.target.value)}
          className="input-field"
        >
          <option value="">{t('Choose a member…')}</option>
          {members.map((m) => (
            <option key={m.id} value={m.id}>
              {m.full_name}
              {m.id === user?.id ? ` (${t('you')})` : ''}
            </option>
          ))}
        </select>
      </div>

      <div>
        <label htmlFor="rec-type" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Paying for')}
        </label>
        <select
          id="rec-type"
          value={type}
          onChange={(e) => setType(e.target.value)}
          className="input-field"
        >
          {TYPES.map((o) => (
            <option key={o.value} value={o.value}>
              {t(o.label)}
            </option>
          ))}
        </select>
      </div>

      {type !== 'savings_deposit' && (
        <div>
          <label htmlFor="rec-related" className="block text-sm font-medium text-slate-700 mb-1">
            {type === 'monthly_fee' ? t('Which fee') : t('Which installment')}
          </label>
          <select
            id="rec-related"
            value={relatedId}
            onChange={(e) => pickRelated(e.target.value)}
            disabled={!memberId || options.length === 0}
            className="input-field disabled:bg-slate-50 disabled:text-slate-400"
          >
            <option value="">
              {!memberId
                ? t('Choose a member first')
                : options.length === 0
                  ? t('Nothing outstanding')
                  : t('Choose…')}
            </option>
            {options.map((o) => (
              <option key={o.id} value={o.id}>
                {o.label}
              </option>
            ))}
          </select>
        </div>
      )}

      <div>
        <label htmlFor="rec-amount" className="block text-sm font-medium text-slate-700 mb-1">
          {t('Amount received (TSh)')}
        </label>
        <input
          id="rec-amount"
          type="number"
          min="0"
          inputMode="numeric"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          placeholder="0"
          className="input-field tabular-nums"
        />
        <p className="mt-1 text-xs text-slate-500">
          {t('Enter what actually arrived, not what was owed.')}
        </p>
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div
        className={`rounded-xl p-3 text-xs ring-1 ring-inset ${
          needsTwo
            ? 'bg-amber-50 ring-amber-200/70 text-amber-800'
            : 'bg-emerald-50 ring-emerald-200/70 text-emerald-800'
        }`}
      >
        {isSelf
          ? t('This is your own money, so a second admin must sign it — even for a monthly fee.')
          : needsTwo
            ? t('A second admin must approve this before it posts.')
            : t('This posts immediately on your signature.')}
      </div>

      <div className="flex gap-2">
        <button type="submit" disabled={busy} className="btn-primary flex-1">
          {busy ? t('Recording…') : t('Record payment')}
        </button>
        <button type="button" onClick={onClose} className="btn-secondary">
          {t('Cancel')}
        </button>
      </div>
    </form>
  )
}

export default function RecordPaymentModal({ open, onClose, members = [], onSubmitted }) {
  const { t } = useLanguage()
  return (
    <Modal open={open} onClose={onClose} title={t('Record a payment')}>
      {open && <Form members={members} onSubmitted={onSubmitted} onClose={onClose} />}
    </Modal>
  )
}
