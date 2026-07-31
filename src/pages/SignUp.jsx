// Self-service registration (v3). Collects login email + password and the member
// KYC fields, or "Continue with Google". The handle_new_user trigger creates a
// PENDING profile; with email-confirmation ON the user must confirm before signing
// in, after which an admin still has to approve their membership.
import { useState } from 'react'
import { Link, Navigate, useNavigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { signUp, REQUIRED_PROFILE_FIELDS } from '../lib/auth'
import ProfileFields from '../components/auth/ProfileFields'
import GoogleButton from '../components/auth/GoogleButton'
import LangToggle from '../components/ui/LangToggle'

const EMPTY = {
  full_name: '',
  phone_number: '',
  secondary_phone: '',
  residence: '',
  national_id: '',
  next_of_kin_name: '',
  next_of_kin_phone: '',
}

export default function SignUp() {
  const { session } = useAuth()
  const { t } = useLanguage()
  const navigate = useNavigate()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [fields, setFields] = useState(EMPTY)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [done, setDone] = useState(false)

  if (session) return <Navigate to="/" replace />

  const onChange = (name, value) => setFields((f) => ({ ...f, [name]: value }))

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!email.trim()) return setError(t('Enter your email.'))
    if (password.length < 8) return setError(t('Password must be at least 8 characters.'))
    const missing = REQUIRED_PROFILE_FIELDS.find((k) => !String(fields[k] || '').trim())
    if (missing) return setError(t('Please fill in all required fields.'))

    setBusy(true)
    try {
      const data = await signUp(email.trim(), password, {
        ...fields,
        full_name: fields.full_name.trim(),
      })
      // Email-confirmation OFF → a session is returned, so route into the gate
      // (which lands on /pending). ON → no session yet; show a check-email notice.
      if (data?.session) navigate('/', { replace: true })
      else setDone(true)
    } catch (err) {
      setError(err?.message || t('Could not create your account.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="relative min-h-dvh bg-slate-50">
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 -top-40 h-[420px] bg-gradient-to-b from-emerald-100/60 via-emerald-50/40 to-transparent"
      />
      <div className="relative flex min-h-dvh flex-col justify-center px-6 py-12">
        <div className="mx-auto w-full max-w-sm">
          <div className="flex flex-col items-center text-center mb-6">
            <h1 className="text-[22px] font-semibold tracking-tight text-slate-900">
              {t('Create your account')}
            </h1>
            <p className="mt-1 text-sm text-slate-500">Micro-SACCOS · Umoja Group</p>
            <div className="mt-2">
              <LangToggle />
            </div>
          </div>

          {done ? (
            <div className="rounded-2xl bg-white p-6 shadow-[0_16px_48px_-24px_rgba(15,23,42,0.18)] ring-1 ring-slate-200/70 space-y-4 text-center">
              <p className="text-sm text-slate-600">
                {t('Almost there — check your email to confirm your address, then sign in. An admin will review your membership.')}
              </p>
              <Link to="/login" className="btn-primary w-full">
                {t('Back to sign in')}
              </Link>
            </div>
          ) : (
            <form
              onSubmit={handleSubmit}
              className="rounded-2xl bg-white p-6 shadow-[0_16px_48px_-24px_rgba(15,23,42,0.18)] ring-1 ring-slate-200/70 space-y-4"
            >
              <GoogleButton label={t('Sign up with Google')} />

              <div className="flex items-center gap-3 text-xs text-slate-400">
                <span className="h-px flex-1 bg-slate-200" />
                {t('or with email')}
                <span className="h-px flex-1 bg-slate-200" />
              </div>

              <div>
                <label htmlFor="signup-email" className="block text-sm font-medium text-slate-700 mb-1">
                  {t('Email')}
                </label>
                <input
                  id="signup-email"
                  type="email"
                  autoComplete="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="input-field"
                  placeholder="you@example.com"
                />
              </div>
              <div>
                <label htmlFor="signup-password" className="block text-sm font-medium text-slate-700 mb-1">
                  {t('Password')}
                </label>
                <input
                  id="signup-password"
                  type="password"
                  autoComplete="new-password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="input-field"
                  placeholder="••••••••"
                />
              </div>

              <ProfileFields values={fields} onChange={onChange} idPrefix="signup" />

              {error && (
                <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 ring-1 ring-inset ring-red-100">
                  {error}
                </p>
              )}

              <button type="submit" disabled={busy} className="btn-primary w-full">
                {busy ? t('Creating…') : t('Create account')}
              </button>
            </form>
          )}

          <p className="mt-6 text-center text-sm text-slate-500">
            {t('Already have an account?')}{' '}
            <Link to="/login" className="font-medium text-emerald-700 hover:text-emerald-800">
              {t('Sign in')}
            </Link>
          </p>
        </div>
      </div>
    </div>
  )
}
