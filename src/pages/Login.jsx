// Login (build plan §9, item 12). Refined per UI/UX Pro Max §5 layout +
// §8 forms: visible labels, large touch targets, helpful focus states, single
// primary CTA, subtle background tint so the card lifts off the page.
//
// Two ways in, and the default is the members' one:
//
//   Phone  — first name + phone number + PIN. What a member actually knows. They
//            have never had a real email: admin-create-member mints a synthetic
//            firstname.lastname@umojagroup.app address and reads out a generated
//            10-character password, and in practice neither is remembered.
//   Email  — email + password, unchanged. This is the admin's path: they have a
//            real inbox, so the reset link below actually reaches them, and it is
//            the fallback if phone login is ever misbehaving.
//
// The PIN is not optional decoration. Name and phone are known to every member of
// the group (full_name is published in-app by group_member_directory), so on their
// own the group's phone list would be a working credential for every account -
// including the admin's, whose session approves loans and records payments. Name and
// phone identify; the PIN authenticates.
import { useState } from 'react'
import { Navigate, useNavigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { signIn, sendPasswordReset } from '../lib/auth'
import { signInWithPhonePin, phoneProblem, pinProblem } from '../lib/phoneAuth'
import LangToggle from '../components/ui/LangToggle'
import PasswordField from '../components/ui/PasswordField'

function BrandMark() {
  return (
    <div className="inline-flex items-center justify-center w-12 h-12 rounded-2xl bg-gradient-to-br from-emerald-500 to-emerald-700 text-white shadow-[0_8px_24px_-12px_rgba(5,150,105,0.6)]">
      <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M12 2l3.09 6.26L22 9.27l-5 4.87L18.18 22 12 18.27 5.82 22 7 14.14 2 9.27l6.91-1.01L12 2z" />
      </svg>
    </div>
  )
}

function Alert({ children }) {
  return (
    <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 ring-1 ring-inset ring-red-100">
      {children}
    </p>
  )
}

// Tabs, not two stacked forms: a member should never scroll past a login they do
// not use, and a browser should never be offered two password fields to fill.
function Tab({ active, onClick, children }) {
  return (
    <button
      type="button"
      role="tab"
      aria-selected={active}
      onClick={onClick}
      className={[
        'flex-1 rounded-xl px-3 py-2.5 text-sm font-medium transition-colors',
        active
          ? 'bg-white text-slate-900 shadow-sm ring-1 ring-slate-200/70'
          : 'text-slate-500 hover:text-slate-700',
      ].join(' ')}
    >
      {children}
    </button>
  )
}

function PhoneForm({ onDone }) {
  const { t } = useLanguage()
  const [firstName, setFirstName] = useState('')
  const [phone, setPhone] = useState('')
  const [pin, setPin] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (busy) return

    if (!firstName.trim()) return setError(t('Enter your first name.'))
    const badPhone = phoneProblem(phone)
    if (badPhone) return setError(t(badPhone))
    // Checked here only to save a round trip on an obvious typo — the Edge
    // Function checks it again and its answer is the one that decides.
    const badPin = pinProblem(pin)
    if (badPin) return setError(t(badPin))

    setBusy(true)
    try {
      const { mustChangePin } = await signInWithPhonePin({ firstName, phone, pin })
      onDone(mustChangePin)
    } catch (err) {
      // Wrapped in t(): these messages are composed in the Edge Function, in
      // English. t() falls back to the key, so one without a Swahili entry still
      // reads correctly rather than coming out blank.
      setError(t(err?.message) || t('Could not sign you in.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div>
        <label htmlFor="first-name" className="block text-sm font-medium text-slate-700 mb-1.5">
          {t('First name')}
        </label>
        <input
          id="first-name"
          type="text"
          autoComplete="given-name"
          autoCapitalize="words"
          required
          value={firstName}
          onChange={(e) => setFirstName(e.target.value)}
          className="input-field"
          placeholder={t('e.g. Jane')}
        />
      </div>

      <div>
        <label htmlFor="phone" className="block text-sm font-medium text-slate-700 mb-1.5">
          {t('Phone number')}
        </label>
        <input
          id="phone"
          type="tel"
          inputMode="tel"
          autoComplete="tel"
          required
          value={phone}
          onChange={(e) => setPhone(e.target.value)}
          className="input-field"
          placeholder="0712 345 678"
        />
        {/* Said plainly because all three forms are in the member list already and
            all three work — nobody should have to guess which one was recorded. */}
        <p className="mt-1 text-xs text-slate-400">
          {t('0712…, +255712… and 255712… all work.')}
        </p>
      </div>

      <PasswordField
        id="pin"
        label={t('PIN')}
        value={pin}
        onChange={(e) => setPin(e.target.value)}
        placeholder="••••"
        autoComplete="current-password"
        inputMode="numeric"
        maxLength={6}
      />

      {error && <Alert>{error}</Alert>}

      <button type="submit" disabled={busy} className="btn-primary w-full">
        {busy ? t('Signing in…') : t('Sign in')}
      </button>

      <p className="text-center text-xs text-slate-400">
        {t('No PIN yet, or forgotten it? Your admin can set you a new one.')}
      </p>
    </form>
  )
}

function EmailForm({ onDone }) {
  const { t } = useLanguage()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    setNotice('')
    setBusy(true)
    try {
      await signIn(email.trim(), password)
      onDone()
    } catch (err) {
      setError(err?.message || t('Sign in failed. Check your email and password.'))
    } finally {
      setBusy(false)
    }
  }

  async function handleForgot() {
    setError('')
    setNotice('')
    if (!email.trim()) {
      setError(t('Enter your email first, then tap "Forgot password?".'))
      return
    }
    // Guarded like the sign-in: this used to be the one action on the screen that
    // could be fired repeatedly while in flight, and each tap is another email.
    if (busy) return
    setBusy(true)
    try {
      await sendPasswordReset(email.trim())
      setNotice(t('If that email exists, a reset link is on its way.'))
    } catch (err) {
      setError(err?.message || t('Could not send the reset email.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div>
        <label htmlFor="email" className="block text-sm font-medium text-slate-700 mb-1.5">
          {t('Email')}
        </label>
        <input
          id="email"
          type="email"
          autoComplete="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          className="input-field"
          placeholder="you@example.com"
        />
      </div>

      <PasswordField
        id="password"
        label={t('Password')}
        value={password}
        onChange={(e) => setPassword(e.target.value)}
        placeholder="••••••••"
        action={
          <button
            type="button"
            onClick={handleForgot}
            disabled={busy}
            className="text-xs font-medium text-emerald-700 hover:text-emerald-800 disabled:opacity-50"
          >
            {t('Forgot?')}
          </button>
        }
      />

      {error && <Alert>{error}</Alert>}
      {notice && (
        <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-700 ring-1 ring-inset ring-emerald-100">
          {notice}
        </p>
      )}

      <button type="submit" disabled={busy} className="btn-primary w-full">
        {busy ? t('Signing in…') : t('Sign in')}
      </button>
    </form>
  )
}

export default function Login() {
  const { session } = useAuth()
  const { t } = useLanguage()
  const navigate = useNavigate()
  const [mode, setMode] = useState('phone')

  if (session) return <Navigate to="/" replace />

  // A member signing in on a PIN the admin issued goes straight to choosing their
  // own. /set-pin holds them there, so this is the courtesy, not the enforcement.
  function afterPhoneLogin(mustChangePin) {
    navigate(mustChangePin ? '/set-pin' : '/', { replace: true })
  }

  return (
    <div className="relative min-h-dvh overflow-hidden bg-slate-50">
      {/* Soft ambient gradient — sets a warmer tone than a flat gray background. */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 -top-40 h-[420px] bg-gradient-to-b from-emerald-100/60 via-emerald-50/40 to-transparent"
      />
      <div className="relative flex min-h-dvh flex-col justify-center px-6 py-12">
        <div className="mx-auto w-full max-w-sm">
          <div className="flex flex-col items-center text-center mb-8">
            <BrandMark />
            <h1 className="mt-4 text-[22px] font-semibold tracking-tight text-slate-900">
              {t('Welcome back')}
            </h1>
            <p className="mt-1 text-sm text-slate-500">
              Micro-SACCOS · Umoja Group
            </p>
            <div className="mt-2">
              <LangToggle />
            </div>
          </div>

          <div className="rounded-2xl bg-white p-6 shadow-auth ring-1 ring-slate-200/70">
            <div role="tablist" className="mb-5 flex gap-1 rounded-2xl bg-slate-100 p-1">
              <Tab active={mode === 'phone'} onClick={() => setMode('phone')}>
                {t('Phone & PIN')}
              </Tab>
              <Tab active={mode === 'email'} onClick={() => setMode('email')}>
                {t('Email')}
              </Tab>
            </div>

            {mode === 'phone' ? (
              <PhoneForm onDone={afterPhoneLogin} />
            ) : (
              <EmailForm onDone={() => navigate('/', { replace: true })} />
            )}
          </div>

          {/* No sign-up link: accounts are created by an admin, who hands over a
              temporary PIN. There is nothing here for a stranger to start. */}
          <p className="mt-6 text-center text-sm text-slate-500">
            {t('Accounts are created by your group admin. Speak to them to get access.')}
          </p>

          <p className="mt-3 text-center text-xs text-slate-400">
            {t('A small group, big trust. Every member can see the group’s savings and loans.')}
          </p>
        </div>
      </div>
    </div>
  )
}
