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

const inputClass =
  'w-full rounded-lg border border-gray-300 px-3 py-2 text-gray-900 outline-none focus:border-emerald-500 focus:ring-2 focus:ring-emerald-200'

function Section({ title, children }) {
  return (
    <section className="rounded-2xl border border-gray-100 bg-white p-4">
      <h2 className="text-sm font-semibold text-gray-900 mb-3">{title}</h2>
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
        <label className="block text-sm font-medium text-gray-700 mb-1">Phone number</label>
        <input
          className={inputClass}
          value={phone}
          onChange={(e) => setPhone(e.target.value)}
          placeholder="+255…"
        />
      </div>
      {error && <p className="text-sm text-red-600">{error}</p>}
      {notice && <p className="text-sm text-emerald-600">{notice}</p>}
      <button
        type="submit"
        disabled={busy}
        className="w-full rounded-lg bg-emerald-600 text-white font-medium py-2.5 hover:bg-emerald-700 disabled:opacity-50"
      >
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
        <label className="block text-sm font-medium text-gray-700 mb-1">New password</label>
        <input
          type="password"
          className={inputClass}
          value={pw}
          onChange={(e) => setPw(e.target.value)}
          autoComplete="new-password"
          placeholder="At least 8 characters"
        />
      </div>
      <div>
        <label className="block text-sm font-medium text-gray-700 mb-1">Confirm</label>
        <input
          type="password"
          className={inputClass}
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
          autoComplete="new-password"
          placeholder="Re-enter password"
        />
      </div>
      {error && <p className="text-sm text-red-600">{error}</p>}
      {notice && <p className="text-sm text-emerald-600">{notice}</p>}
      <button
        type="submit"
        disabled={busy}
        className="w-full rounded-lg bg-emerald-600 text-white font-medium py-2.5 hover:bg-emerald-700 disabled:opacity-50"
      >
        {busy ? 'Saving…' : 'Change password'}
      </button>
    </form>
  )
}

function ContributionRow({ label, value }) {
  return (
    <div className="flex justify-between text-sm">
      <span className="text-gray-500">{label}</span>
      <span className="text-gray-900">{formatTZS(value)}</span>
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
      <p className="text-sm text-gray-500">
        Download a CSV with your savings, fees, loans, and full submission history.
      </p>
      {error && <p className="text-sm text-red-600">{error}</p>}
      <button
        onClick={handleDownload}
        disabled={busy}
        className="w-full rounded-lg bg-emerald-600 text-white font-medium py-2.5 hover:bg-emerald-700 disabled:opacity-50"
      >
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
  if (savings == null) return <p className="text-sm text-gray-400">Loading…</p>

  return (
    <div className="space-y-2">
      <ContributionRow label="Total savings" value={savings} />
      <p className="text-xs text-gray-400 mt-2">
        Includes your savings deposits, paid monthly fees, and any admin-approved
        adjustments. Your loan ceiling is 3× this amount (capped at 25% of the group pool).
      </p>
    </div>
  )
}

export default function Profile() {
  const { profile, user, refreshProfile } = useAuth()
  const navigate = useNavigate()
  const home = profile?.role === 'admin' ? '/admin' : '/dashboard'

  return (
    <div className="min-h-screen bg-gray-50">
      <header className="bg-white border-b border-gray-100 sticky top-0 z-10">
        <div className="max-w-md mx-auto px-6 py-4 flex items-center justify-between">
          <div className="min-w-0">
            <p className="text-xs text-gray-400">Micro-SACCOS</p>
            <h1 className="text-lg font-semibold text-gray-900 truncate">Profile</h1>
          </div>
          <Link to={home} className="text-sm text-gray-500 hover:text-gray-700 shrink-0">
            ← Back
          </Link>
        </div>
      </header>

      <main className="max-w-md mx-auto px-6 py-6 space-y-4">
        <Section title="Account">
          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-gray-500">Name</span>
              <span className="text-gray-900">{profile?.full_name || '—'}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Email</span>
              <span className="text-gray-900 break-all">{user?.email}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">Role</span>
              <span className="text-gray-900 capitalize">{profile?.role}</span>
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
          className="w-full rounded-lg border border-gray-200 py-2 text-sm text-gray-600 hover:bg-white"
        >
          Back to dashboard
        </button>
      </main>
    </div>
  )
}
