// Meetings, attendance and the social fund (migration 030).
//
// The register defaults everyone to present and the admin marks the exceptions —
// in a 15-member group that is far less tapping than the other way round.
//
// Applying the fines is a separate, explicit step because it is irreversible: it
// deducts straight from savings rather than raising an invoice.
import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../supabaseClient'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { useGroupSettings } from '../hooks/useGroupSettings'
import { formatTZS, formatDate } from '../lib/format'
import { getMemberDirectory } from '../lib/directory'
import {
  ATTENDANCE,
  lastMeetingOnOrBefore,
  getMeetings,
  getAttendance,
  recordMeeting,
  setAttendance,
  applyAttendanceFines,
  getSocialFund,
  recordSocialContribution,
  recordSocialContributionForAll,
  requestSocialGrant,
  approveSocialGrant,
  rejectSocialGrant,
} from '../lib/meetings'
import AppHeader from '../components/ui/AppHeader'
import Name from '../components/ui/Name'
import BottomNav from '../components/ui/BottomNav'

const CARD =
  'rounded-2xl border border-slate-200/70 bg-white p-4 sm:p-5 shadow-card'

const TONE = {
  present: 'bg-emerald-50 text-emerald-700 ring-emerald-200',
  late: 'bg-amber-50 text-amber-700 ring-amber-200',
  excused: 'bg-slate-50 text-slate-600 ring-slate-200',
  absent: 'bg-red-50 text-red-700 ring-red-200',
}

function Register({ meeting, names, onChanged }) {
  const { t } = useLanguage()
  const { settings } = useGroupSettings()
  const [rows, setRows] = useState([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    try {
      setRows(await getAttendance(supabase, meeting.id))
    } catch (err) {
      setError(err?.message || '')
    }
  }, [meeting.id])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  const applied = !!meeting.fines_applied_at
  // Previewed from the same two settings the RPC reads, so the admin sees the bill
  // before committing to it.
  const preview = rows.reduce(
    (sum, r) =>
      sum +
      (r.status === 'late'
        ? Number(settings.attendance_fine_late ?? 0)
        : r.status === 'absent'
          ? Number(settings.attendance_fine_absent ?? 0)
          : 0),
    0,
  )
  const collected = rows.reduce((s, r) => s + Number(r.fine_tzs || 0), 0)

  async function mark(memberId, status) {
    setError('')
    setBusy(true)
    try {
      await setAttendance(supabase, meeting.id, memberId, status)
      await load()
    } catch (err) {
      setError(err?.message || t('Could not save attendance.'))
    } finally {
      setBusy(false)
    }
  }

  async function applyFines() {
    setError('')
    if (
      !window.confirm(
        t('Deduct {amount} from members’ savings? This cannot be undone.').replace(
          '{amount}',
          formatTZS(preview),
        ),
      )
    )
      return
    setBusy(true)
    try {
      await applyAttendanceFines(supabase, meeting.id)
      await load()
      onChanged?.()
    } catch (err) {
      setError(err?.message || t('Could not apply the fines.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="mt-3 pt-3 border-t border-slate-100 space-y-2">
      <ul className="divide-y divide-slate-100">
        {rows.map((r) => (
          <li key={r.member_id} className="flex items-center justify-between gap-2 py-2">
            <span className="text-sm text-slate-900 truncate min-w-0">
              {names[r.member_id] || t('unknown')}
            </span>
            {applied ? (
              <span className="flex items-center gap-2 shrink-0">
                <span
                  className={`rounded-full px-2 py-0.5 text-[11px] ring-1 ring-inset ${TONE[r.status]}`}
                >
                  {t(r.status)}
                </span>
                {Number(r.fine_tzs) > 0 && (
                  <span className="text-xs tabular-nums text-red-700">
                    −{formatTZS(r.fine_tzs)}
                  </span>
                )}
              </span>
            ) : (
              <select
                value={r.status}
                onChange={(e) => mark(r.member_id, e.target.value)}
                disabled={busy}
                aria-label={t('Attendance for {name}').replace(
                  '{name}',
                  names[r.member_id] || '',
                )}
                className="text-xs rounded-lg border border-slate-200 px-2 py-1 shrink-0"
              >
                {ATTENDANCE.map((s) => (
                  <option key={s} value={s}>
                    {t(s)}
                  </option>
                ))}
              </select>
            )}
          </li>
        ))}
      </ul>

      {error && <p className="text-sm text-red-600">{error}</p>}

      {applied ? (
        <p className="text-xs text-slate-500">
          {t('{amount} in fines was deducted on {date}.')
            .replace('{amount}', formatTZS(collected))
            .replace('{date}', formatDate(meeting.fines_applied_at?.slice(0, 10)))}
        </p>
      ) : (
        <>
          <p className="text-xs text-slate-500">
            {preview > 0
              ? t('{amount} in fines will be deducted straight from savings. Nobody is invoiced.').replace(
                  '{amount}',
                  formatTZS(preview),
                )
              : t('Nobody is being fined for this meeting.')}
          </p>
          <button onClick={applyFines} disabled={busy || preview <= 0} className="btn-danger w-full">
            {busy ? t('Working…') : t('Apply the fines')}
          </button>
        </>
      )}
    </div>
  )
}

function NewMeeting({ onCreated }) {
  const { t } = useLanguage()
  const [open, setOpen] = useState(false)
  // The group meets on the last Saturday of the month, so that — not today — is
  // the date being recorded almost every time. Still editable for a rescheduled
  // or extraordinary meeting.
  const [heldOn, setHeldOn] = useState(() => lastMeetingOnOrBefore())
  const [title, setTitle] = useState('')
  const [minutes, setMinutes] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  async function submit(e) {
    e.preventDefault()
    setError('')
    if (!title.trim()) return setError(t('Give the meeting a title.'))
    setBusy(true)
    try {
      await recordMeeting(supabase, heldOn, title.trim(), minutes.trim())
      setTitle('')
      setMinutes('')
      setOpen(false)
      onCreated?.()
    } catch (err) {
      setError(err?.message || t('Could not record the meeting.'))
    } finally {
      setBusy(false)
    }
  }

  if (!open) {
    return (
      <button onClick={() => setOpen(true)} className="btn-primary w-full">
        {t('+ Record a meeting')}
      </button>
    )
  }

  return (
    <form onSubmit={submit} className={`${CARD} space-y-3`}>
      <input
        type="date"
        value={heldOn}
        onChange={(e) => setHeldOn(e.target.value)}
        aria-label={t('Date held')}
        className="input-field"
      />
      <input
        type="text"
        value={title}
        onChange={(e) => setTitle(e.target.value)}
        placeholder={t('e.g. Monthly meeting — March')}
        aria-label={t('Title')}
        className="input-field"
      />
      <textarea
        value={minutes}
        onChange={(e) => setMinutes(e.target.value)}
        rows={3}
        placeholder={t('Minutes (optional)')}
        aria-label={t('Minutes (optional)')}
        className="input-field"
      />
      {error && <p className="text-sm text-red-600">{error}</p>}
      <div className="flex gap-2">
        <button type="submit" disabled={busy} className="btn-primary flex-1">
          {busy ? t('Working…') : t('Record it')}
        </button>
        <button type="button" onClick={() => setOpen(false)} className="btn-secondary">
          {t('Cancel')}
        </button>
      </div>
    </form>
  )
}

// The monthly welfare contribution is the same figure for every member, so the
// picker offers the whole group as one choice. Only for contributions: a grant is
// money going OUT to one member in need, and it takes a second admin's approval —
// there is no such thing as proposing one for everybody at once.
const EVERYONE = '__everyone__'

function SocialFund({ fund, members, currentAdminId, onChanged }) {
  const { t } = useLanguage()
  const [mode, setMode] = useState(null)
  const [pick, setPick] = useState('')
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  // The outcome of a whole-group run, kept outside the form because the form
  // closes on success and a partial run still has to be read and acted on.
  const [note, setNote] = useState(null)

  if (!fund) return null

  // Clearing the pick matters here: leaving it on EVERYONE while switching to
  // 'grant' would carry a choice the grant form does not offer.
  function start(next) {
    setMode(next)
    setPick('')
    setError('')
    setNote(null)
  }

  function close() {
    setMode(null)
    setPick('')
    setError('')
  }

  const everyone = mode === 'contribution' && pick === EVERYONE
  const amountNumber = Number(amount)

  async function submit(e) {
    e.preventDefault()
    setError('')
    setNote(null)
    const n = amountNumber
    if (!pick) return setError(t('Choose a member.'))
    if (!(n > 0)) return setError(t('Enter an amount greater than zero.'))
    if (!reason.trim()) return setError(t('A reason is required.'))
    if (everyone && members.length === 0) return setError(t('There are no members to record for.'))
    setBusy(true)
    try {
      if (everyone) {
        const { saved, failed } = await recordSocialContributionForAll(
          supabase,
          members.map((m) => m.id),
          n,
          reason.trim(),
        )
        if (failed.length > 0) {
          // Named, because the rest of the group is already recorded — the admin
          // needs to finish these few one at a time, not run the whole lot again.
          const names = failed
            .map(({ memberId }) => members.find((m) => m.id === memberId)?.name || t('A member'))
            .join(', ')
          setNote({
            ok: false,
            text: t('Saved for {n} of {total}. Not saved for: {names}')
              .replace('{n}', String(saved.length))
              .replace('{total}', String(members.length))
              .replace('{names}', names),
          })
        } else {
          setNote({
            ok: true,
            text: t('Saved for all {n} members.').replace('{n}', String(saved.length)),
          })
        }
      } else if (mode === 'contribution') {
        await recordSocialContribution(supabase, pick, n, reason.trim())
      } else {
        await requestSocialGrant(supabase, pick, n, reason.trim())
      }
      setPick('')
      setAmount('')
      setReason('')
      setMode(null)
      onChanged?.()
    } catch (err) {
      setError(err?.message || t('Could not save that.'))
    } finally {
      setBusy(false)
    }
  }

  async function vote(id, approve) {
    setError('')
    setBusy(true)
    try {
      if (approve) await approveSocialGrant(supabase, id)
      else await rejectSocialGrant(supabase, id)
      onChanged?.()
    } catch (err) {
      setError(err?.message || t('Could not save that.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className={CARD}>
      <div className="flex items-baseline justify-between mb-1">
        <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">
          {t('Social fund')}
        </h2>
        <span className="text-sm font-semibold tabular-nums text-slate-900">
          {formatTZS(fund.balance?.balance_tzs ?? 0)}
        </span>
      </div>
      <p className="text-xs text-slate-400 mb-3">
        {t('Welfare money for emergencies. Kept separate from the loan pool — it is never lent out.')}
      </p>

      {fund.pendingGrants.length > 0 && (
        <div className="rounded-xl bg-amber-50 ring-1 ring-inset ring-amber-200/70 p-3 mb-3 space-y-2">
          {fund.pendingGrants.map((g) => (
            <div key={g.id} className="space-y-1">
              <div className="flex justify-between text-sm">
                <span className="text-amber-900">
                  {members.find((m) => m.id === g.member_id)?.name || t('A member')}
                </span>
                <span className="tabular-nums text-amber-900">{formatTZS(g.amount)}</span>
              </div>
              <p className="text-xs text-amber-800">{g.reason}</p>
              <div className="flex gap-2">
                <button
                  onClick={() => vote(g.id, true)}
                  disabled={busy || g.requested_by === currentAdminId}
                  className="btn-info flex-1 text-xs py-1.5 disabled:opacity-40"
                >
                  {g.requested_by === currentAdminId ? t('You proposed this') : t('Approve')}
                </button>
                <button
                  onClick={() => vote(g.id, false)}
                  disabled={busy}
                  className="btn-secondary text-xs py-1.5"
                >
                  {t('Reject')}
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {note && (
        <div
          className={`rounded-xl p-3 mb-3 text-xs ring-1 ring-inset ${
            note.ok
              ? 'bg-emerald-50 ring-emerald-200/70 text-emerald-900'
              : 'bg-amber-50 ring-amber-200/70 text-amber-900'
          }`}
        >
          {/* The failure note names members, and a name is not a word to translate. */}
          <span translate={note.ok ? undefined : 'no'}>{note.text}</span>
        </div>
      )}

      {mode ? (
        <form onSubmit={submit} className="space-y-2">
          <select
            value={pick}
            onChange={(e) => setPick(e.target.value)}
            aria-label={t('Choose a member')}
            className="input-field"
          >
            <option value="">{t('Choose a member…')}</option>
            {mode === 'contribution' && members.length > 0 && (
              <option value={EVERYONE}>
                {t('Every member — the same amount each ({n})').replace(
                  '{n}',
                  String(members.length),
                )}
              </option>
            )}
            {members.map((m) => (
              <option key={m.id} value={m.id} translate="no">
                {m.name}
              </option>
            ))}
          </select>
          <input
            type="text"
            inputMode="decimal"
            value={amount}
            onChange={(e) => setAmount(e.target.value.replace(/[^\d.]/g, ''))}
            placeholder={everyone ? t('Amount each (TSh)') : t('Amount (TSh)')}
            aria-label={everyone ? t('Amount each (TSh)') : t('Amount (TSh)')}
            className="input-field tabular-nums"
          />
          {everyone && amountNumber > 0 && (
            <p className="text-xs text-slate-500 tabular-nums">
              {t('{n} members × {each} = {total} into the fund')
                .replace('{n}', String(members.length))
                .replace('{each}', formatTZS(amountNumber))
                .replace('{total}', formatTZS(amountNumber * members.length))}
            </p>
          )}
          <input
            type="text"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder={
              mode === 'contribution'
                ? t('e.g. monthly welfare contribution')
                : t('e.g. funeral costs')
            }
            aria-label={t('Reason')}
            className="input-field"
          />
          {error && <p className="text-sm text-red-600">{error}</p>}
          <div className="flex gap-2">
            <button type="submit" disabled={busy} className="btn-primary flex-1">
              {busy
                ? everyone
                  ? t('Saving for everyone…')
                  : t('Working…')
                : t('Save')}
            </button>
            <button type="button" onClick={close} className="btn-secondary">
              {t('Cancel')}
            </button>
          </div>
        </form>
      ) : (
        <div className="grid grid-cols-2 gap-2">
          <button onClick={() => start('contribution')} className="btn-secondary text-xs">
            {t('Record a contribution')}
          </button>
          <button onClick={() => start('grant')} className="btn-secondary text-xs">
            {t('Propose a grant')}
          </button>
        </div>
      )}
    </section>
  )
}

export default function Meetings() {
  const { profile, user } = useAuth()
  const { t } = useLanguage()
  const [meetings, setMeetings] = useState([])
  const [members, setMembers] = useState([])
  const [fund, setFund] = useState(null)
  const [openId, setOpenId] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    if (!supabase) return
    try {
      const [ms, dir, f] = await Promise.all([
        getMeetings(supabase),
        getMemberDirectory(supabase),
        getSocialFund(supabase).catch(() => null),
      ])
      setMeetings(ms)
      setMembers(dir)
      setFund(f)
      setError('')
    } catch (err) {
      setError(err?.message || t('Could not load meetings. Has migration 030 been applied?'))
    } finally {
      setLoading(false)
    }
  }, [t])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  const names = Object.fromEntries(members.map((m) => [m.id, m.name]))

  return (
    <div className="min-h-dvh bg-[var(--color-app-bg)]">
      <AppHeader
        eyebrow={t('Micro-SACCOS · Admin')}
        title={<Name>{profile?.full_name || user?.email}</Name>}
        width="max-w-4xl"
        links={[{ to: '/admin', label: t('← Admin') }]}
      />

      <main className="max-w-4xl mx-auto px-4 sm:px-6 py-5 sm:py-6 space-y-4 pb-nav">
        {error && (
          <div className="rounded-xl border border-red-200/70 bg-red-50 p-3 text-sm text-red-700">
            {error}
          </div>
        )}

        {loading ? (
          <p className="text-center text-slate-400 py-8">{t('Loading…')}</p>
        ) : (
          <>
            <NewMeeting onCreated={load} />

            <SocialFund
              fund={fund}
              members={members}
              currentAdminId={user?.id}
              onChanged={load}
            />

            {meetings.map((m) => (
              <section key={m.id} className={CARD}>
                <button
                  onClick={() => setOpenId(openId === m.id ? null : m.id)}
                  className="w-full text-left"
                >
                  <div className="flex items-baseline justify-between gap-3">
                    <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">
                      {m.title}
                    </h2>
                    <span className="text-xs text-slate-400 shrink-0">
                      {formatDate(m.held_on)}
                    </span>
                  </div>
                  <p className="text-xs text-slate-400 mt-0.5">
                    {m.fines_applied_at ? t('Fines applied') : t('Register open')}
                  </p>
                </button>

                {m.minutes && (
                  <p className="mt-2 text-sm text-slate-600 whitespace-pre-wrap">{m.minutes}</p>
                )}

                {openId === m.id && <Register meeting={m} names={names} onChanged={load} />}
              </section>
            ))}

            {meetings.length === 0 && (
              <p className="text-center text-slate-400 py-8">{t('No meetings recorded yet.')}</p>
            )}

            <Link to="/admin" className="btn-secondary w-full inline-flex justify-center">
              {t('← Admin')}
            </Link>
          </>
        )}
      </main>

      <BottomNav isAdmin />
    </div>
  )
}
