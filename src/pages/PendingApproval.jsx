// Pending-approval screen (v3). Shown to a signed-in member whose profile is
// complete but not yet activated by an admin (is_active=false). They can re-check
// their status or sign out. The route gate forwards them to /complete-profile if
// details are still missing, or to the dashboard once an admin approves.
import { useState } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { isProfileComplete, signOut } from '../lib/auth'
import LangToggle from '../components/ui/LangToggle'

export default function PendingApproval() {
  const { profile, refreshProfile } = useAuth()
  const { t } = useLanguage()
  const [checking, setChecking] = useState(false)

  if (!isProfileComplete(profile)) return <Navigate to="/complete-profile" replace />
  if (profile?.is_active) return <Navigate to="/" replace />

  async function recheck() {
    setChecking(true)
    try {
      await refreshProfile()
    } finally {
      setChecking(false)
    }
  }

  return (
    <div className="relative min-h-dvh bg-slate-50 flex items-center justify-center px-6 py-12">
      <div className="w-full max-w-sm text-center">
        <div className="mx-auto mb-4 inline-flex h-12 w-12 items-center justify-center rounded-2xl bg-amber-50 ring-1 ring-inset ring-amber-200 text-amber-600">
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <circle cx="12" cy="12" r="9" />
            <path d="M12 7v5l3 2" />
          </svg>
        </div>
        <h1 className="text-[20px] font-semibold tracking-tight text-slate-900">
          {t('Awaiting approval')}
        </h1>
        <p className="mt-2 text-sm text-slate-500">
          {t('Thanks, {name}! Your details are in. An admin will review and activate your account soon.')
            .replace('{name}', (profile?.full_name || '').split(' ')[0] || t('there'))}
        </p>

        <div className="mt-6 space-y-2">
          <button onClick={recheck} disabled={checking} className="btn-primary w-full">
            {checking ? t('Checking…') : t('Check status')}
          </button>
          <button onClick={() => signOut()} className="btn-ghost w-full">
            {t('Sign out')}
          </button>
        </div>
        <div className="mt-6 flex justify-center">
          <LangToggle />
        </div>
      </div>
    </div>
  )
}
