// Record one payment for a member — savings deposit, a single monthly fee, a loan
// repayment, or a fine for arriving late or missing the meeting. The fee sheet handles
// the monthly bulk; this is for everything that varies, and for the admin's own money.
//
// How many signatures it needs depends on what is being recorded, so the modal says
// which case applies BEFORE the admin commits. The rule lives in SQL
// (submission_threshold); this only mirrors it for the message.
import { useCallback, useEffect, useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { useAuth } from '../../hooks/useAuth'
import { useLanguage } from '../../hooks/useLanguage'
import { useGroupSettings } from '../../hooks/useGroupSettings'
import { FINE_SETTING, recordPayment } from '../../lib/payments'
import { formatTZS, formatDate } from '../../lib/format'
import { loanLabel } from '../../lib/loans'

const TYPES = [
  { value: 'savings_deposit', label: 'Savings deposit' },
  { value: 'monthly_fee', label: 'Monthly fee' },
  { value: 'loan_installment', label: 'Loan repayment' },
  { value: 'fine_late', label: 'Fine for arriving late' },
  { value: 'fine_absent', label: 'Fine for missing a meeting' },
]

// Only these two pay against a specific row, so only they get the picker.
const settlesRow = (type) => type === 'monthly_fee' || type === 'loan_installment'
const isFine = (type) => type in FINE_SETTING

function Form({ members, onSubmitted, onClose }) {
  const { user, isOverseer } = useAuth()
  const { t } = useLanguage()
  const { settings, refresh } = useGroupSettings()
  const [memberId, setMemberId] = useState('')
  const [type, setType] = useState('savings_deposit')
  const [relatedId, setRelatedId] = useState('')
  const [amount, setAmount] = useState('')
  const [options, setOptions] = useState([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const isSelf = memberId && memberId === user?.id
  // The overseer settles everything on one signature, their own money included
  // (041), so promising a second admin here would be a lie the RPC then contradicts.
  const needsTwo = !isOverseer && (isSelf || (type !== 'monthly_fee' && !isFine(type)))
  // Read from the settings the group voted. Undefined only if they failed to load, and
  // then the RPC, which holds the same ceiling, is the one to say so.
  const fineCeiling = settings[FINE_SETTING[type]]

  // What this member can actually pay against, for the two types that settle a
  // specific row. Refetched whenever the member or type changes so the picker can
  // never offer a row belonging to somebody else.
  const loadOptions = useCallback(async () => {
    setOptions([])
    setRelatedId('')
    if (!supabase || !memberId || !settlesRow(type)) return
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
          .select('id, principal, disbursed_at')
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
        // With two loans there are two #1s, so each option has to say whose it is.
        const whichLoan = (i) =>
          loans.length > 1 ? `${loanLabel(loans.find((l) => l.id === i.loan_id), t)} · ` : ''
        setOptions(
          [...data]
            .sort((a, b) => a.due_date.localeCompare(b.due_date))
            .map((i) => ({
              id: i.id,
              label: `${whichLoan(i)}#${i.installment_number} — ${formatDate(i.due_date)} — ${formatTZS(
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

  // The provider loads settings once. A form left open across a vote on the fines would
  // otherwise fill in the old amount and refuse the new one until someone reloaded.
  useEffect(() => {
    refresh()
  }, [refresh])

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

  // A fine's amount is the group's, so it arrives filled in. It is taken away again on
  // the way out: left in the box, 4,000 would quietly become a deposit of 4,000.
  function changeType(next) {
    setType(next)
    setError('')
    if (isFine(next)) {
      const fine = Number(settings[FINE_SETTING[next]])
      setAmount(fine > 0 ? String(fine) : '')
    } else if (isFine(type)) {
      setAmount('')
    }
  }

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!memberId) return setError(t('Choose a member.'))
    if (!(Number(amount) > 0)) return setError(t('Enter an amount greater than zero.'))
    if (settlesRow(type) && !relatedId) {
      return setError(t('Choose which fee or installment this payment settles.'))
    }
    if (isFine(type) && fineCeiling !== undefined && Number(amount) > Number(fineCeiling)) {
      return setError(
        t('This fine is {amount}. Enter what actually arrived, up to that amount.').replace(
          '{amount}',
          formatTZS(fineCeiling),
        ),
      )
    }
    setBusy(true)
    try {
      await recordPayment(supabase, {
        memberId,
        submissionType: type,
        relatedId: settlesRow(type) ? relatedId : null,
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
            <option key={m.id} value={m.id} translate="no">
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
          onChange={(e) => changeType(e.target.value)}
          className="input-field"
        >
          {TYPES.map((o) => (
            <option key={o.value} value={o.value}>
              {t(o.label)}
            </option>
          ))}
        </select>
      </div>

      {settlesRow(type) && (
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
        {isFine(type) && (
          <p className="mt-1 text-xs text-slate-500">
            {t('This goes into the group’s money for lending. It does not add to the member’s savings.')}
          </p>
        )}
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div
        className={`rounded-xl p-3 text-xs ring-1 ring-inset ${
          needsTwo
            ? 'bg-amber-50 ring-amber-200/70 text-amber-800'
            : 'bg-emerald-50 ring-emerald-200/70 text-emerald-800'
        }`}
      >
        {isSelf && needsTwo
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
