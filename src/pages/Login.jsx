// Login (build plan §9, item 12). Refined per UI/UX Pro Max §5 layout +
// §8 forms: visible labels, large touch targets, helpful focus states, single
// primary CTA, subtle background tint so the card lifts off the page.
import { useState } from 'react'
import { Navigate, useNavigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { signIn, sendPasswordReset } from '../lib/auth'

function BrandMark() {
  return (
    <div className="inline-flex items-center justify-center w-12 h-12 rounded-2xl bg-gradient-to-br from-emerald-500 to-emerald-700 text-white shadow-[0_8px_24px_-12px_rgba(5,150,105,0.6)]">
      <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M12 2l3.09 6.26L22 9.27l-5 4.87L18.18 22 12 18.27 5.82 22 7 14.14 2 9.27l6.91-1.01L12 2z" />
      </svg>
    </div>
  )
}

export default function Login() {
  const { session } = useAuth()
  const navigate = useNavigate()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  if (session) return <Navigate to="/" replace />

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    setNotice('')
    setBusy(true)
    try {
      await signIn(email.trim(), password)
      navigate('/', { replace: true })
    } catch (err) {
      setError(err?.message || 'Sign in failed. Check your email and password.')
    } finally {
      setBusy(false)
    }
  }

  async function handleForgot() {
    setError('')
    setNotice('')
    if (!email.trim()) {
      setError('Enter your email first, then tap “Forgot password?”.')
      return
    }
    try {
      await sendPasswordReset(email.trim())
      setNotice('If that email exists, a reset link is on its way.')
    } catch (err) {
      setError(err?.message || 'Could not send the reset email.')
    }
  }

  return (
    <div className="relative min-h-screen overflow-hidden bg-slate-50">
      {/* Soft ambient gradient — sets a warmer tone than a flat gray background. */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 -top-40 h-[420px] bg-gradient-to-b from-emerald-100/60 via-emerald-50/40 to-transparent"
      />
      <div className="relative flex min-h-screen flex-col justify-center px-6 py-12">
        <div className="mx-auto w-full max-w-sm">
          <div className="flex flex-col items-center text-center mb-8">
            <BrandMark />
            <h1 className="mt-4 text-[22px] font-semibold tracking-tight text-slate-900">
              Welcome back
            </h1>
            <p className="mt-1 text-sm text-slate-500">
              Micro-SACCOS · Umoja Group
            </p>
          </div>

          <form
            onSubmit={handleSubmit}
            className="rounded-2xl bg-white p-6 shadow-[0_16px_48px_-24px_rgba(15,23,42,0.18)] ring-1 ring-slate-200/70 space-y-4"
          >
            <div>
              <label htmlFor="email" className="block text-sm font-medium text-slate-700 mb-1.5">
                Email
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

            <div>
              <div className="flex items-baseline justify-between mb-1.5">
                <label htmlFor="password" className="block text-sm font-medium text-slate-700">
                  Password
                </label>
                <button
                  type="button"
                  onClick={handleForgot}
                  className="text-xs font-medium text-emerald-700 hover:text-emerald-800"
                >
                  Forgot?
                </button>
              </div>
              <input
                id="password"
                type="password"
                autoComplete="current-password"
                required
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="input-field"
                placeholder="••••••••"
              />
            </div>

            {error && (
              <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 ring-1 ring-inset ring-red-100">
                {error}
              </p>
            )}
            {notice && (
              <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-700 ring-1 ring-inset ring-emerald-100">
                {notice}
              </p>
            )}

            <button type="submit" disabled={busy} className="btn-primary w-full">
              {busy ? 'Signing in…' : 'Sign in'}
            </button>
          </form>

          <p className="mt-6 text-center text-xs text-slate-400">
            A small group, big trust. Your savings are visible only to you and the admin team.
          </p>
        </div>
      </div>
    </div>
  )
}
