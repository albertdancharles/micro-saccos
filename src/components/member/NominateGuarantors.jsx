// Nominate co-signers for a loan request that is still pending (migration 028).
//
// Sits inside the "awaiting approval" state of LoanRequestForm rather than in the
// request form itself, because a guarantee has to attach to a loan that exists —
// and because the borrower usually needs to go and ask people first.
//
// Admins cannot approve the loan while any nomination is unanswered, so the card
// is explicit about who is still to reply.
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../supabaseClient'
import { formatTZS } from '../../lib/format'
import { getLoanGuarantors, nominateGuarantor, cancelGuarantee } from '../../lib/guarantors'
import { getMemberDirectory } from '../../lib/directory'
import { useLanguage } from '../../hooks/useLanguage'

const LABEL = {
  pending: 'Awaiting their answer',
  accepted: 'Accepted',
  declined: 'Declined',
  released: 'Released',
  called: 'Called',
}

export default function NominateGuarantors({ loan, memberId, onChanged }) {
  const { t } = useLanguage()
  // Read out of `loan` before the callback: an optional-chained dependency
  // (`loan?.id`) defeats the React Compiler's memoization analysis.
  const loanId = loan?.id ?? null
  const [rows, setRows] = useState([])
  const [members, setMembers] = useState([])
  const [pick, setPick] = useState('')
  const [amount, setAmount] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [unavailable, setUnavailable] = useState(false)

  const load = useCallback(async () => {
    if (!supabase || !loanId) return
    try {
      const [gs, dir] = await Promise.all([
        getLoanGuarantors(supabase, loanId),
        getMemberDirectory(supabase),
      ])
      setRows(gs)
      setMembers((dir || []).filter((m) => m.id !== memberId))
    } catch {
      setUnavailable(true)
    }
  }, [loanId, memberId])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  if (unavailable) return null

  const taken = new Set(rows.map((r) => r.guarantor_id))
  const available = members.filter((m) => !taken.has(m.id))
  const amountNum = Number(amount)

  async function add(e) {
    e.preventDefault()
    setError('')
    if (!pick) return setError(t('Choose a member.'))
    if (!(amountNum > 0)) return setError(t('Enter an amount greater than zero.'))
    setBusy(true)
    try {
      await nominateGuarantor(supabase, loanId, pick, amountNum)
      setPick('')
      setAmount('')
      await load()
      onChanged?.()
    } catch (err) {
      setError(err?.message || t('Could not ask them.'))
    } finally {
      setBusy(false)
    }
  }

  async function remove(id) {
    setError('')
    setBusy(true)
    try {
      await cancelGuarantee(supabase, id)
      await load()
      onChanged?.()
    } catch (err) {
      setError(err?.message || t('Could not withdraw the request.'))
    } finally {
      setBusy(false)
    }
  }

  const waiting = rows.filter((r) => r.status === 'pending').length

  return (
    <div className="mt-4 pt-4 border-t border-slate-100 space-y-3">
      <div>
        <p className="text-sm font-medium text-slate-900">{t('Guarantors')}</p>
        <p className="text-xs text-slate-500 mt-0.5">
          {waiting > 0
            ? t('Your loan cannot be approved until all {n} nominated member(s) have answered.')
                .replace('{n}', waiting)
            : t('Optional. Members who back your loan pledge part of their own savings against it.')}
        </p>
      </div>

      {rows.length > 0 && (
        <ul className="divide-y divide-slate-100">
          {rows.map((g) => (
            <li key={g.id} className="flex items-center justify-between gap-3 py-2">
              <div className="min-w-0">
                <p className="text-sm text-slate-900 truncate">
                  {members.find((m) => m.id === g.guarantor_id)?.name || t('unknown')}
                </p>
                <p
                  className={`text-xs mt-0.5 ${
                    g.status === 'accepted'
                      ? 'text-emerald-700'
                      : g.status === 'declined'
                        ? 'text-red-600'
                        : 'text-slate-500'
                  }`}
                >
                  {t(LABEL[g.status] || g.status)}
                </p>
              </div>
              <div className="flex items-center gap-2 shrink-0">
                <span className="text-sm tabular-nums text-slate-900">
                  {formatTZS(g.pledged_amount)}
                </span>
                {g.status === 'pending' && (
                  <button
                    onClick={() => remove(g.id)}
                    disabled={busy}
                    className="text-xs text-slate-500 hover:text-red-600 underline underline-offset-2"
                  >
                    {t('Withdraw')}
                  </button>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}

      {available.length > 0 && (
        <form onSubmit={add} className="space-y-2">
          <select
            value={pick}
            onChange={(e) => setPick(e.target.value)}
            aria-label={t('Choose a member')}
            className="input-field"
          >
            <option value="">{t('Ask a member to guarantee…')}</option>
            {available.map((m) => (
              <option key={m.id} value={m.id}>
                {m.name}
              </option>
            ))}
          </select>
          <input
            type="text"
            inputMode="decimal"
            value={amount}
            onChange={(e) => setAmount(e.target.value.replace(/[^\d.]/g, ''))}
            placeholder={t('Amount (TSh)')}
            aria-label={t('Amount (TSh)')}
            className="input-field tabular-nums"
          />
          {error && <p className="text-sm text-red-600">{error}</p>}
          <button type="submit" disabled={busy} className="btn-secondary w-full">
            {busy ? t('Working…') : t('Ask them')}
          </button>
        </form>
      )}
    </div>
  )
}
