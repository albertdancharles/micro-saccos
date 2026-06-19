// Update password (build plan §9, item 12). Landing route for the reset-email
// link: Supabase establishes a recovery session from the URL, then the user
// sets a new password. Also works for a signed-in user changing their password.
import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { updatePassword } from '../lib/auth'
import { supabase } from '../supabaseClient'
import { useLanguage } from '../hooks/useLanguage'

export default function UpdatePassword() {
  const navigate = useNavigate()
  const { t } = useLanguage()
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [hasSession, setHasSession] = useState(false)
  const [checking, setChecking] = useState(Boolean(supabase))

  useEffect(() => {
    if (!supabase) return
    supabase.auth.getSession().then(({ data }) => {
      setHasSession(!!data.session)
      setChecking(false)
    })
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === 'PASSWORD_RECOVERY' || session) setHasSession(true)
    })
    return () => subscription.unsubscribe()
  }, [])

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (password.length < 8) return setError(t('Use at least 8 characters.'))
    if (password !== confirm) return setError(t('Passwords do not match.'))
    setBusy(true)
    try {
      await updatePassword(password)
      navigate('/', { replace: true })
    } catch (err) {
      setError(err?.message || t('Could not update your password.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="relative min-h-screen overflow-hidden bg-slate-50">
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 -top-40 h-[420px] bg-gradient-to-b from-emerald-100/60 via-emerald-50/40 to-transparent"
      />
      <div className="relative flex min-h-screen flex-col justify-center px-6 py-12">
        <div className="mx-auto w-full max-w-sm">
          <div className="text-center mb-8">
            <h1 className="text-[22px] font-semibold tracking-tight text-slate-900">
              {t('Set a new password')}
            </h1>
            <p className="mt-1 text-sm text-slate-500">{t("Choose something you'll remember.")}</p>
          </div>

          {checking ? (
            <p className="text-center text-sm text-slate-400">{t('Checking your link…')}</p>
          ) : !hasSession ? (
            <div className="rounded-2xl bg-white p-6 text-center shadow-[0_16px_48px_-24px_rgba(15,23,42,0.18)] ring-1 ring-slate-200/70 space-y-3">
              <p className="text-sm text-slate-600">
                {t('This reset link is invalid or has expired.')}
              </p>
              <button
                onClick={() => navigate('/login', { replace: true })}
                className="btn-primary w-full"
              >
                {t('Back to sign in')}
              </button>
            </div>
          ) : (
            <form
              onSubmit={handleSubmit}
              className="rounded-2xl bg-white p-6 shadow-[0_16px_48px_-24px_rgba(15,23,42,0.18)] ring-1 ring-slate-200/70 space-y-4"
            >
              <div>
                <label htmlFor="password" className="block text-sm font-medium text-slate-700 mb-1.5">
                  {t('New password')}
                </label>
                <input
                  id="password"
                  type="password"
                  autoComplete="new-password"
                  required
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="input-field"
                  placeholder={t('At least 8 characters')}
                />
              </div>

              <div>
                <label htmlFor="confirm" className="block text-sm font-medium text-slate-700 mb-1.5">
                  {t('Confirm password')}
                </label>
                <input
                  id="confirm"
                  type="password"
                  autoComplete="new-password"
                  required
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                  className="input-field"
                  placeholder={t('Re-enter password')}
                />
              </div>

              {error && (
                <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 ring-1 ring-inset ring-red-100">
                  {error}
                </p>
              )}

              <button type="submit" disabled={busy} className="btn-primary w-full">
                {busy ? t('Saving…') : t('Save password')}
              </button>
            </form>
          )}
        </div>
      </div>
    </div>
  )
}
