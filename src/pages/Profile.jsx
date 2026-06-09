// Profile / self-service (Phase 1c). Members can update their phone, change their
// password, and view a breakdown of what they've contributed (savings + paid fees).
// Reduces the admin's manual reset and update burden.
import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { updatePassword } from '../lib/auth'
import { updateOwnPhone } from '../lib/profile'
import { getApprovedSavings } from '../lib/savings'
import { buildMemberStatement, downloadBlob } from '../lib/statements'
import { supabase } from '../supabaseClient'
import { formatTZS } from '../lib/format'

function Section({ title, children }) {
  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-3">{title}</h2>
      {children}
    </section>
  )
}

function PhoneForm({ initialPhone, onSaved }) {
  const [phone, setPhone] = useState(initialPhone || '')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    setNotice('')
    setBusy(true)
    try {
      await updateOwnPhone(phone.trim())
      setNotice('Phone number updated.')
      onSaved?.()
    } catch (err) {
      setError(err?.message || 'Could not update phone.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">Phone number</label>
        <input
          className="input-field"
          value={phone}
          onChange={(e) => setPhone(e.target.value)}
          placeholder="+255…"
        />
      </div>
      {error && <p className="text-sm text-red-600">{error}</p>}
      {notice && <p className="text-sm text-emerald-700">{notice}</p>}
      <button type="submit" disabled={busy} className="btn-primary w-full">
        {busy ? 'Saving…' : 'Save phone'}
      </button>
    </form>
  )
}

function PasswordForm() {
  const [pw, setPw] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    setNotice('')
    if (pw.length < 8) return setError('Use at least 8 characters.')
    if (pw !== confirm) return setError('Passwords do not match.')
    setBusy(true)
    try {
      await updatePassword(pw)
      setNotice('Password changed.')
      setPw('')
      setConfirm('')
    } catch (err) {
      setError(err?.message || 'Could not change password.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">New password</label>
        <input
          type="password"
          className="input-field"
          value={pw}
          onChange={(e) => setPw(e.target.value)}
          autoComplete="new-password"
          placeholder="At least 8 characters"
        />
      </div>
      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">Confirm</label>
        <input
          type="password"
          className="input-field"
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
          autoComplete="new-password"
          placeholder="Re-enter password"
        />
      </div>
      {error && <p className="text-sm text-red-600">{error}</p>}
      {notice && <p className="text-sm text-emerald-700">{notice}</p>}
      <button type="submit" disabled={busy} className="btn-primary w-full">
        {busy ? 'Saving…' : 'Change password'}
      </button>
    </form>
  )
}

function ContributionRow({ label, value }) {
  return (
    <div className="flex justify-between text-sm">
      <span className="text-slate-500">{label}</span>
      <span className="text-slate-900 tabular-nums">{formatTZS(value)}</span>
    </div>
  )
}

function StatementSection({ memberId, memberName, memberEmail }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  async function handleDownload() {
    if (!memberId) return
    setError('')
    setBusy(true)
    try {
      const blob = await buildMemberStatement(supabase, {
        memberId,
        memberName: memberName || '',
        memberEmail: memberEmail || '',
      })
      const slug = (memberName || 'statement')
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-|-$/g, '')
      const today = new Date().toISOString().slice(0, 10)
      downloadBlob(blob, `${slug}-statement-${today}.csv`)
    } catch (err) {
      setError(err?.message || 'Could not generate the statement.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="space-y-2">
      <p className="text-sm text-slate-500">
        Download a CSV with your savings, fees, loans, and full submission history.
      </p>
      {error && <p className="text-sm text-red-600">{error}</p>}
      <button onClick={handleDownload} disabled={busy} className="btn-primary w-full">
        {busy ? 'Preparing…' : 'Download statement (CSV)'}
      </button>
    </div>
  )
}

function ContributionsCard({ memberId }) {
  const [savings, setSavings] = useState(null)
  const [err, setErr] = useState('')

  useEffect(() => {
    if (!supabase || !memberId) return
    let cancelled = false
    getApprovedSavings(supabase, memberId)
      .then((s) => {
        if (!cancelled) setSavings(s)
      })
      .catch((e) => {
        if (!cancelled) setErr(e?.message || 'Could not load contributions.')
      })
    return () => {
      cancelled = true
    }
  }, [memberId])

  if (err) return <p className="text-sm text-red-600">{err}</p>
  if (savings == null) return <p className="text-sm text-slate-400">Loading…</p>

  return (
    <div className="space-y-2">
      <ContributionRow label="Total savings" value={savings} />
      <p className="text-xs text-slate-400 mt-2">
        Includes your savings deposits, paid monthly fees, and any admin-approved
        adjustments. Your loan ceiling is 5× this amount (capped at 25% of the group pool).
      </p>
    </div>
  )
}

export default function Profile() {
  const { profile, user, refreshProfile } = useAuth()
  const navigate = useNavigate()
  const home = profile?.role === 'admin' ? '/admin' : '/dashboard'

  return (
    <div className="min-h-screen bg-[var(--color-app-bg)]">
      <header className="bg-white/85 backdrop-blur-md border-b border-slate-200/70 sticky top-0 z-10">
        <div className="max-w-md mx-auto px-6 py-4 flex items-center justify-between gap-3">
          <div className="min-w-0">
            <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-emerald-600">
              Micro-SACCOS
            </p>
            <h1 className="text-base font-semibold tracking-tight text-slate-900 truncate">
              Profile
            </h1>
          </div>
          <Link
            to={home}
            className="text-sm font-medium text-slate-500 hover:text-slate-800 shrink-0"
          >
            ← Back
          </Link>
        </div>
      </header>

      <main className="max-w-md mx-auto px-6 py-6 space-y-4">
        <Section title="Account">
          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-slate-500">Name</span>
              <span className="text-slate-900">{profile?.full_name || '—'}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-slate-500">Email</span>
              <span className="text-slate-900 break-all">{user?.email}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-slate-500">Role</span>
              <span className="text-slate-900 capitalize">{profile?.role}</span>
            </div>
          </div>
        </Section>

        <Section title="Phone number">
          <PhoneForm initialPhone={profile?.phone_number} onSaved={refreshProfile} />
        </Section>

        <Section title="Change password">
          <PasswordForm />
        </Section>

        <Section title="My contributions">
          <ContributionsCard memberId={user?.id} />
        </Section>

        <Section title="Statement">
          <StatementSection
            memberId={user?.id}
            memberName={profile?.full_name}
            memberEmail={user?.email}
          />
        </Section>

        <button
          onClick={() => navigate(home, { replace: true })}
          className="btn-secondary w-full"
        >
          Back to dashboard
        </button>
      </main>
    </div>
  )
}
