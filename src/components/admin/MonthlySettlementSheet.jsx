// Settle the month — the whole group, one press (migration 049).
//
// The group's money all moves at one meeting, so the monthly fee and the loan interest
// arrive together, from nearly everyone, in amounts the system already knows. Keying
// that member by member is the work this replaces. The sheet lists what has fallen
// due with everybody ticked, and the admin's only job is to untick whoever did not pay.
//
// Amounts cannot be typed here, on purpose. Each is exactly what the row owes, and
// the server reads it back again before posting. A member who paid part goes through
// "Record a payment", as does any repayment of principal.
//
// It records money as received, so a wrong press marks people paid who are not. That
// is why it asks twice, and why a row can be voided on its own afterwards (037).
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../supabaseClient'
import { useAuth } from '../../hooks/useAuth'
import { useLanguage } from '../../hooks/useLanguage'
import {
  getSettlementSheet,
  membersFrom,
  recordMonthlySettlement,
  rowKey,
  summarise,
} from '../../lib/settlement'
import { formatMonth, formatTZS } from '../../lib/format'

export default function MonthlySettlementSheet({ onActioned, refreshSignal }) {
  const { user } = useAuth()
  const { t } = useLanguage()
  const [rows, setRows] = useState([])
  const [unticked, setUnticked] = useState(() => new Set())
  const [loading, setLoading] = useState(true)
  const [loadFailed, setLoadFailed] = useState(false)
  const [open, setOpen] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [result, setResult] = useState(null)

  const load = useCallback(async () => {
    if (!supabase) return
    try {
      setRows(await getSettlementSheet(supabase))
      setLoadFailed(false)
    } catch (err) {
      console.error('monthly_settlement_sheet failed', err)
      setLoadFailed(true)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
    // refreshSignal is the dashboard's data: when another admin settles someone, or a
    // payment is keyed elsewhere, the figures here have to follow.
  }, [load, refreshSignal])

  const whole = summarise(rows)
  const selected = summarise(rows, unticked)
  const members = membersFrom(rows, unticked)
  const nothingTicked = selected.ticked.length === 0

  // Any change to the selection changes the figure being confirmed, so it has to be
  // confirmed again.
  function replaceUnticked(next) {
    setUnticked(next)
    setConfirming(false)
  }

  function toggleRow(row) {
    const next = new Set(unticked)
    const key = rowKey(row)
    if (next.has(key)) next.delete(key)
    else next.add(key)
    replaceUnticked(next)
  }

  function toggleMember(member) {
    const next = new Set(unticked)
    for (const row of member.rows) {
      if (member.allTicked) next.add(rowKey(row))
      else next.delete(rowKey(row))
    }
    replaceUnticked(next)
  }

  function openSheet() {
    setResult(null)
    setError('')
    setOpen(true)
  }

  async function handleSettle() {
    setError('')
    setBusy(true)
    try {
      const posted = await recordMonthlySettlement(supabase, selected.ticked)
      setResult(posted)
      setUnticked(new Set())
      setConfirming(false)
      setOpen(false)
      await load()
      onActioned?.()
    } catch (err) {
      // All-or-nothing server-side, so nothing posted. Reload in case the refusal was
      // because the figures moved, and keep the admin's unticks.
      setError(err?.message || t('Could not settle the month.'))
      setConfirming(false)
      await load()
    } finally {
      setBusy(false)
    }
  }

  if (loading) return <div className="skeleton h-28 w-full rounded-2xl" />

  if (loadFailed) {
    return (
      <section className="rounded-2xl border border-slate-200/70 bg-white p-4 shadow-card">
        <h2 className="text-sm font-semibold text-slate-900">{t('Settle the month')}</h2>
        <p className="mt-1 text-xs text-slate-500">{t('Could not load the month’s settlement.')}</p>
      </section>
    )
  }

  const outcome = result && (
    <div
      role="status"
      className="space-y-1 rounded-xl bg-emerald-50 p-3 text-xs text-emerald-800 ring-1 ring-inset ring-emerald-200/70"
    >
      {Number(result.settled_total) > 0 && (
        <p>{t('Done. {amount} is recorded.').replace('{amount}', formatTZS(result.settled_total))}</p>
      )}
      {Number(result.awaiting_total) > 0 && (
        <p>
          {t('{amount} is waiting for a second admin’s signature, under Approvals.').replace(
            '{amount}',
            formatTZS(result.awaiting_total),
          )}
        </p>
      )}
    </div>
  )

  if (!open) {
    return (
      <section className="space-y-3 rounded-2xl border border-emerald-200/70 bg-white p-4 shadow-card sm:p-5">
        <div>
          <h2 className="text-sm font-semibold text-slate-900">{t('Settle the month')}</h2>
          <p className="mt-0.5 text-xs text-slate-500">
            {t('Monthly fees and loan interest for the whole group, in one go.')}
          </p>
        </div>

        {outcome}

        {rows.length === 0 ? (
          <p className="text-xs text-slate-500">
            {t('Nothing is due right now. Anything waiting for a second signature is under Approvals.')}
          </p>
        ) : (
          <>
            <div>
              <p className="text-2xl font-semibold tracking-tight text-slate-900 tabular-nums">
                {formatTZS(whole.total)}
              </p>
              <p className="mt-0.5 text-xs text-slate-500 tabular-nums">
                {t('Fees {fees} · Interest {interest} · Members {n}')
                  .replace('{fees}', formatTZS(whole.fees))
                  .replace('{interest}', formatTZS(whole.interest))
                  .replace('{n}', whole.members)}
              </p>
            </div>
            <button onClick={openSheet} className="btn-primary w-full !min-h-12">
              {t('Review and settle everyone')}
            </button>
          </>
        )}
      </section>
    )
  }

  const someUnticked = selected.ticked.length < rows.length

  return (
    <section
      data-panel-enter
      className="space-y-3 rounded-2xl border border-emerald-200/70 bg-white p-4 shadow-card sm:p-5"
    >
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold text-slate-900">{t('Settle the month')}</h2>
        <button
          onClick={() => setOpen(false)}
          className="text-sm text-slate-500 hover:text-slate-700"
        >
          {t('Close')}
        </button>
      </div>

      {rows.length === 0 ? (
        <p className="py-4 text-center text-sm text-slate-500">
          {t('Nothing is due right now. Anything waiting for a second signature is under Approvals.')}
        </p>
      ) : (
        <>
          <div className="flex items-start justify-between gap-3">
            <p className="text-xs text-slate-500">
              {t('Everyone is ticked. Untick anyone who did not pay — they stay owing.')}
            </p>
            <button
              onClick={() =>
                replaceUnticked(someUnticked ? new Set() : new Set(rows.map(rowKey)))
              }
              className="shrink-0 text-xs font-medium text-emerald-700 hover:text-emerald-800 hover:underline underline-offset-2"
            >
              {someUnticked ? t('Tick everyone') : t('Untick everyone')}
            </button>
          </div>

          {/* Up here, not below the list: an admin should know this is going to wait
              for someone else before scrolling past fourteen members to press. */}
          <p
            className={`rounded-xl p-3 text-xs ring-1 ring-inset ${
              selected.awaiting > 0
                ? 'bg-amber-50 text-amber-800 ring-amber-200/70'
                : 'bg-emerald-50 text-emerald-800 ring-emerald-200/70'
            }`}
          >
            {selected.awaiting > 0
              ? t('{amount} of this needs a second admin’s signature: loan interest, and your own money. The rest posts immediately.').replace(
                  '{amount}',
                  formatTZS(selected.awaiting),
                )
              : t('All of this posts immediately on your signature.')}
          </p>

          <div className="divide-y divide-slate-100">
            {members.map((member, i) => (
              <MemberRow
                key={member.id}
                member={member}
                index={i}
                isYou={member.id === user?.id}
                unticked={unticked}
                onToggleMember={toggleMember}
                onToggleRow={toggleRow}
              />
            ))}
          </div>

          <p className="text-xs text-slate-500">
            {t('Loan principal is not settled here. Record a repayment with “Record a payment”.')}
          </p>

          {error && <p className="text-sm text-red-600">{error}</p>}

          {/* Same offset as the fee sheet: bottom-0 would park this under the fixed tab
              bar on mobile and hide the button that does the work. */}
          <div className="sticky bottom-[calc(var(--bottom-nav-h)+env(safe-area-inset-bottom,0px))] -mx-4 border-t border-slate-100 bg-white/95 px-4 py-3 backdrop-blur sm:bottom-0 sm:-mx-5 sm:px-5">
            {confirming ? (
              <div className="space-y-2">
                <p className="text-sm text-slate-700">
                  {t('Record {amount} as received? Only do this once the money is really in hand.').replace(
                    '{amount}',
                    formatTZS(selected.total),
                  )}
                </p>
                <div className="flex gap-2">
                  <button onClick={handleSettle} disabled={busy} className="btn-primary flex-1">
                    {busy ? t('Settling…') : t('Yes, settle')}
                  </button>
                  <button
                    onClick={() => setConfirming(false)}
                    disabled={busy}
                    className="btn-secondary"
                  >
                    {t('Cancel')}
                  </button>
                </div>
              </div>
            ) : (
              <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                <p className="text-sm text-slate-600 tabular-nums">
                  {t('Members {n} · {amount}')
                    .replace('{n}', selected.members)
                    .replace('{amount}', formatTZS(selected.total))}
                </p>
                <button
                  onClick={() => setConfirming(true)}
                  disabled={nothingTicked}
                  className="btn-primary w-full sm:w-auto"
                >
                  {t('Settle {amount}').replace('{amount}', formatTZS(selected.total))}
                </button>
              </div>
            )}
          </div>
        </>
      )}
    </section>
  )
}

function MemberRow({ member, index, isYou, unticked, onToggleMember, onToggleRow }) {
  const { t } = useLanguage()
  return (
    <div data-row-enter style={{ '--row-index': index }} className="py-2">
      <div className="flex items-center gap-3">
        <label className="flex min-h-11 min-w-0 flex-1 cursor-pointer items-center gap-3">
          <input
            type="checkbox"
            checked={member.allTicked}
            ref={(el) => {
              if (el) el.indeterminate = member.someTicked && !member.allTicked
            }}
            onChange={() => onToggleMember(member)}
            className="size-5 shrink-0 rounded border-slate-300 text-emerald-600 focus:ring-emerald-500"
          />
          <span className="truncate text-sm text-slate-900" translate="no">
            {member.name}
          </span>
        </label>
        {isYou && <span className="shrink-0 text-xs text-slate-400">{t('you')}</span>}
        <span
          className={`shrink-0 text-sm tabular-nums ${
            member.someTicked ? 'font-medium text-slate-900' : 'text-slate-400'
          }`}
        >
          {formatTZS(member.tickedTotal)}
        </span>
      </div>
      <div className="ml-8 flex flex-wrap gap-1.5">
        {member.rows.map((row) => (
          <RowChip
            key={rowKey(row)}
            row={row}
            on={!unticked.has(rowKey(row))}
            onToggle={() => onToggleRow(row)}
          />
        ))}
      </div>
    </div>
  )
}

// One thing this member owes. The month is shown because a member in arrears has more
// than one of each, and those are different debts.
function RowChip({ row, on, onToggle }) {
  const { t } = useLanguage()
  const isFee = row.kind === 'fee'
  const label = `${isFee ? t('Fee') : t('Interest')} · ${formatMonth(isFee ? row.period : row.due_date)}`
  return (
    <label
      className={`inline-flex min-h-9 cursor-pointer items-center gap-1.5 rounded-lg px-2 py-1 text-xs ring-1 ring-inset transition-colors ${
        on
          ? 'bg-emerald-50 text-emerald-800 ring-emerald-200/70'
          : 'bg-slate-50 text-slate-400 ring-slate-200'
      }`}
    >
      <input
        type="checkbox"
        checked={on}
        onChange={onToggle}
        className="size-3.5 shrink-0 rounded border-slate-300 text-emerald-600 focus:ring-emerald-500"
      />
      <span>{label}</span>
      <span className="tabular-nums font-medium">{formatTZS(row.amount)}</span>
      {row.penalty > 0 && (
        <span className={on ? 'text-amber-700' : ''}>
          {t('penalty {amount}').replace('{amount}', formatTZS(row.penalty))}
        </span>
      )}
    </label>
  )
}
