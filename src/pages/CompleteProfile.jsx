// Complete-profile step (v3). Reached when a signed-in user is missing required
// KYC fields — chiefly Google sign-ups, who arrive with only a name + email. Saves
// via update_own_profile (which can't change role/is_active), then the route gate
// forwards to /pending (awaiting approval) or the dashboard.
import { useState } from 'react'
import { Navigate, useNavigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { updateOwnProfile, isProfileComplete, REQUIRED_PROFILE_FIELDS, signOut } from '../lib/auth'
import ProfileFields from '../components/auth/ProfileFields'
import LangToggle from '../components/ui/LangToggle'

export default function CompleteProfile() {
  const { profile, refreshProfile } = useAuth()
  const { t } = useLanguage()
  const navigate = useNavigate()
  const [fields, setFields] = useState({
    full_name: profile?.full_name || '',
    phone_number: profile?.phone_number || '',
    secondary_phone: profile?.secondary_phone || '',
    residence: profile?.residence || '',
    national_id: profile?.national_id || '',
    next_of_kin_name: profile?.next_of_kin_name || '',
    next_of_kin_phone: profile?.next_of_kin_phone || '',
  })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  // Already complete → let the gate route onward (pending or dashboard).
  if (isProfileComplete(profile)) return <Navigate to="/" replace />

  const onChange = (name, value) => setFields((f) => ({ ...f, [name]: value }))

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    const missing = REQUIRED_PROFILE_FIELDS.find((k) => !String(fields[k] || '').trim())
    if (missing) return setError(t('Please fill in all required fields.'))
    setBusy(true)
    try {
      await updateOwnProfile(fields)
      await refreshProfile()
      navigate('/', { replace: true })
    } catch (err) {
      setError(err?.message || t('Could not save your details.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="relative min-h-dvh bg-slate-50">
      <div className="relative flex min-h-dvh flex-col justify-center px-6 py-12">
        <div className="mx-auto w-full max-w-sm">
          <div className="flex flex-col items-center text-center mb-6">
            <h1 className="text-[22px] font-semibold tracking-tight text-slate-900">
              {t('Complete your profile')}
            </h1>
            <p className="mt-1 text-sm text-slate-500">
              {t('A few details before an admin reviews your membership.')}
            </p>
            <div className="mt-2">
              <LangToggle />
            </div>
          </div>

          <form
            onSubmit={handleSubmit}
            className="rounded-2xl bg-white p-6 shadow-[0_16px_48px_-24px_rgba(15,23,42,0.18)] ring-1 ring-slate-200/70 space-y-4"
          >
            {profile?.email && (
              <p className="text-xs text-slate-400">
                {t('Signed in as')} <span className="text-slate-600">{profile.email}</span>
              </p>
            )}

            <ProfileFields values={fields} onChange={onChange} idPrefix="complete" />

            {error && (
              <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 ring-1 ring-inset ring-red-100">
                {error}
              </p>
            )}

            <button type="submit" disabled={busy} className="btn-primary w-full">
              {busy ? t('Saving…') : t('Save and continue')}
            </button>
            <button type="button" onClick={() => signOut()} className="btn-ghost w-full">
              {t('Sign out')}
            </button>
          </form>
        </div>
      </div>
    </div>
  )
}
