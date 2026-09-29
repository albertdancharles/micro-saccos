// Who can actually sign in, and the one button that fixes it when they cannot.
//
// Members sign in with their first name, phone number and a PIN (042). The PIN is
// the only part an admin can do anything about, and there is no self-service reset:
// a synthetic @umojagroup.app address has no inbox, so a reset email would go
// nowhere. That makes this panel the whole recovery path, which is why it shows
// state rather than just offering a button — an admin fielding "I can't get in"
// needs to see whether the member never set a PIN, is locked out from bad attempts,
// or is sitting on a code that was read out to them weeks ago.
//
// A reset returns the new PIN once. It is not stored in the clear and cannot be
// looked up again, exactly like the temp password from admin-create-member, so it
// stays on screen until the admin dismisses it.
import { useCallback, useEffect, useState } from 'react'
import { useLanguage } from '../../hooks/useLanguage'
import { getMemberPinOverview, resetMemberPin } from '../../lib/phoneAuth'
import { formatDate } from '../../lib/format'
import { fillNames } from '../ui/fillNames'

function Badge({ tone, children }) {
  const tones = {
    ok: 'bg-emerald-50 text-emerald-700 ring-emerald-100',
    warn: 'bg-amber-50 text-amber-700 ring-amber-100',
    bad: 'bg-red-50 text-red-700 ring-red-100',
    idle: 'bg-slate-100 text-slate-500 ring-slate-200',
  }
  return (
    <span
      className={`shrink-0 rounded-full px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide ring-1 ring-inset ${tones[tone]}`}
    >
      {children}
    </span>
  )
}

export default function MemberPinsPanel() {
  const { t } = useLanguage()
  const [rows, setRows] = useState(null)
  const [error, setError] = useState('')
  const [busyId, setBusyId] = useState(null)
  const [issued, setIssued] = useState(null) // { full_name, pin }

  const load = useCallback(async () => {
    try {
      setRows(await getMemberPinOverview())
    } catch (err) {
      setError(err?.message || 'Could not load PIN status.')
    }
  }, [])

  useEffect(() => {
    // Every setState in load() runs after an await, so this effect body writes no
    // state synchronously — the rule cannot see through the useCallback to tell.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  async function handleReset(row) {
    setError('')
    if (busyId) return
    setBusyId(row.member_id)
    try {
      const result = await resetMemberPin(row.member_id)
      setIssued({ full_name: row.full_name, pin: result?.pin })
      await load()
    } catch (err) {
      setError(err?.message || 'Could not reset the PIN.')
    } finally {
      setBusyId(null)
    }
  }

  if (!rows) return null

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-4 sm:p-5 shadow-card">
      <div className="mb-1 flex items-baseline gap-2">
        <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">
          {t('Sign-in PINs')}
        </h2>
        <span className="text-xs text-slate-400 tabular-nums">
          {t('{n} total').replace('{n}', rows.length)}
        </span>
      </div>
      <p className="mb-3 text-xs text-slate-500">
        {t('Members sign in with their first name, phone number and PIN. Reset one only for the member standing in front of you.')}
      </p>

      {issued && (
        <div className="mb-3 rounded-xl bg-emerald-50 p-3 ring-1 ring-inset ring-emerald-100">
          <p className="text-xs text-emerald-800">
            {fillNames(t('New PIN for {name} — read it out now, it is not shown again.'), {
              name: issued.full_name,
            })}
          </p>
          <p className="mt-1 font-mono text-2xl tracking-[0.3em] text-emerald-900">{issued.pin}</p>
          <button
            type="button"
            onClick={() => setIssued(null)}
            className="mt-2 text-xs font-medium text-emerald-700 hover:text-emerald-800"
          >
            {t('Done')}
          </button>
        </div>
      )}

      {error && (
        <p role="alert" className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 ring-1 ring-inset ring-red-100">
          {error}
        </p>
      )}

      <ul className="divide-y divide-slate-100">
        {rows.map((row) => {
          const locked = Boolean(row.locked_until)
          return (
            <li key={row.member_id} className="flex items-center justify-between gap-3 py-2.5">
              <div className="min-w-0">
                <p className="truncate text-sm text-slate-700" translate="no">{row.full_name}</p>
                {row.has_pin && row.set_at && (
                  <p className="text-[11px] text-slate-400">
                    {t('set {date}').replace('{date}', formatDate(row.set_at))}
                  </p>
                )}
              </div>
              <div className="flex shrink-0 items-center gap-2">
                {locked ? (
                  <Badge tone="bad">{t('locked out')}</Badge>
                ) : !row.has_pin ? (
                  <Badge tone="idle">{t('no PIN')}</Badge>
                ) : row.must_change ? (
                  /* The admin knows this one too, so the account is not yet only
                     theirs. ProtectedRoute holds them on /set-pin until they
                     change it, so this state should be short-lived. */
                  <Badge tone="warn">{t('admin-set')}</Badge>
                ) : (
                  <Badge tone="ok">{t('own PIN')}</Badge>
                )}
                <button
                  type="button"
                  onClick={() => handleReset(row)}
                  disabled={busyId === row.member_id}
                  className="btn-secondary text-xs"
                >
                  {busyId === row.member_id ? t('Working…') : t('Reset')}
                </button>
              </div>
            </li>
          )
        })}
      </ul>
    </section>
  )
}
