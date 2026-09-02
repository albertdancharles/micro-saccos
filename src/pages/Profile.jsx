// Profile / self-service (Phase 1c). Members can update their phone, change their
// password, and view a breakdown of what they've contributed (savings + paid fees).
// Reduces the admin's manual reset and update burden.
import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { useGroupSettings } from '../hooks/useGroupSettings'
import { signOut, updatePassword } from '../lib/auth'
import { updateOwnPhone } from '../lib/profile'
import { getApprovedSavings } from '../lib/savings'
import { buildMemberStatement, downloadBlob } from '../lib/statements'
import { supabase } from '../supabaseClient'
import { formatTZS } from '../lib/format'
import AppHeader from '../components/ui/AppHeader'
import BottomNav from '../components/ui/BottomNav'
import NotificationPrefs from '../components/member/NotificationPrefs'

function Section({ title, children }) {
  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-4 sm:p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-slate-900 mb-3">{title}</h2>
      {children}
    </section>
  )
}

function PhoneForm({ initialPhone, onSaved }) {
  const { t } = useLanguage()
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
      setNotice(t('Phone number updated.'))
      onSaved?.()
    } catch (err) {
      setError(err?.message || t('Could not update phone.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">{t('Phone number')}</label>
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
        {busy ? t('Saving…') : t('Save phone')}
      </button>
    </form>
  )
}

function PasswordForm() {
  const { t } = useLanguage()
  const [pw, setPw] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    setNotice('')
    if (pw.length < 8) return setError(t('Use at least 8 characters.'))
    if (pw !== confirm) return setError(t('Passwords do not match.'))
    setBusy(true)
    try {
      await updatePassword(pw)
      setNotice(t('Password changed.'))
      setPw('')
      setConfirm('')
    } catch (err) {
      setError(err?.message || t('Could not change password.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">{t('New password')}</label>
        <input
          type="password"
          className="input-field"
          value={pw}
          onChange={(e) => setPw(e.target.value)}
          autoComplete="new-password"
          placeholder={t('At least 8 characters')}
        />
      </div>
      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">{t('Confirm')}</label>
        <input
          type="password"
          className="input-field"
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
          autoComplete="new-password"
          placeholder={t('Re-enter password')}
        />
      </div>
      {error && <p className="text-sm text-red-600">{error}</p>}
      {notice && <p className="text-sm text-emerald-700">{notice}</p>}
      <button type="submit" disabled={busy} className="btn-primary w-full">
        {busy ? t('Saving…') : t('Change password')}
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
  const { t } = useLanguage()
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
      setError(err?.message || t('Could not generate the statement.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="space-y-2">
      <p className="text-sm text-slate-500">
        {t('Download a CSV with your savings, fees, loans, and full submission history.')}
      </p>
      {error && <p className="text-sm text-red-600">{error}</p>}
      <button onClick={handleDownload} disabled={busy} className="btn-primary w-full">
        {busy ? t('Preparing…') : t('Download statement (CSV)')}
      </button>
    </div>
  )
}

function ContributionsCard({ memberId }) {
  const { t } = useLanguage()
  const { settings } = useGroupSettings()
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
        if (!cancelled) setErr(e?.message || t('Could not load contributions.'))
      })
    return () => {
      cancelled = true
    }
  }, [memberId]) // eslint-disable-line react-hooks/exhaustive-deps

  if (err) return <p className="text-sm text-red-600">{err}</p>
  if (savings == null) return <p className="text-sm text-slate-400">{t('Loading…')}</p>

  return (
    <div className="space-y-2">
      <ContributionRow label={t('Total savings')} value={savings} />
      <p className="text-xs text-slate-400 mt-2">
        {t('Includes your savings deposits, paid monthly fees, and any admin-approved adjustments. Your loan ceiling is {n}× this amount (capped at {p}% of the group pool).')
          .replace('{n}', settings.contribution_multiplier)
          .replace('{p}', Number((settings.pool_loan_fraction * 100).toFixed(2)))}
      </p>
    </div>
  )
}

export default function Profile() {
  const { profile, user, refreshProfile } = useAuth()
  const { t } = useLanguage()
  const navigate = useNavigate()
  const home = profile?.role === 'admin' ? '/admin' : '/dashboard'

  async function handleSignOut() {
    await signOut()
    navigate('/login', { replace: true })
  }

  return (
    <div className="min-h-dvh bg-[var(--color-app-bg)]">
      <AppHeader
        eyebrow={t('Micro-SACCOS')}
        title={t('Profile')}
        back={{ to: home, label: t('← Back') }}
      />

      <main className="max-w-md mx-auto px-4 sm:px-6 py-5 sm:py-6 space-y-4 pb-nav">
        <Section title={t('Account')}>
          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-slate-500">{t('Name')}</span>
              <span className="text-slate-900">{profile?.full_name || '—'}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-slate-500">{t('Email')}</span>
              <span className="text-slate-900 break-all">{user?.email}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-slate-500">{t('Role')}</span>
              <span className="text-slate-900 capitalize">{profile?.role}</span>
            </div>
          </div>
        </Section>

        <Section title={t('Phone number')}>
          <PhoneForm initialPhone={profile?.phone_number} onSaved={refreshProfile} />
        </Section>

        <Section title={t('Reminders')}>
          <NotificationPrefs memberId={user?.id} />
        </Section>

        <Section title={t('Change password')}>
          <PasswordForm />
        </Section>

        <Section title={t('My contributions')}>
          <ContributionsCard memberId={user?.id} />
        </Section>

        <Section title={t('Statement')}>
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
          {t('Back to dashboard')}
        </button>

        {/* Sign out lives here on mobile. It used to sit only in the header,
            which the tab bar replaced — and the account screen is where people
            look for it anyway. */}
        <button onClick={handleSignOut} className="btn-ghost w-full !text-red-600 sm:hidden">
          {t('Sign out')}
        </button>
      </main>

      <BottomNav isAdmin={profile?.role === 'admin'} />
    </div>
  )
}
