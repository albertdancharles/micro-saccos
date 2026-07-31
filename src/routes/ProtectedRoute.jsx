// Route guard (build plan §3, item 24; v3 onboarding). Redirects unauthenticated
// users to /login and gates admin-only routes. Self-registration adds two gates
// between "signed in" and "full member":
//   * incomplete profile (e.g. Google sign-up) → /complete-profile
//   * pending admin approval (is_active=false)  → /pending
// The onboarding pages themselves mount under <ProtectedRoute requireComplete=
// {false} requireActive={false}/> so they require only a session and never bounce
// to themselves.
import { Navigate, Outlet } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { isProfileComplete } from '../lib/auth'

function FullScreen({ children }) {
  return (
    <div className="min-h-dvh flex items-center justify-center text-gray-500">
      {children}
    </div>
  )
}

export default function ProtectedRoute({
  requireAdmin = false,
  requireComplete = true,
  requireActive = true,
}) {
  const { session, profile, loading, loadingProfile } = useAuth()
  const { t } = useLanguage()

  if (loading) return <FullScreen>{t('Loading…')}</FullScreen>
  if (!session) return <Navigate to="/login" replace />

  // Hold rendering until we know the profile, so a member isn't briefly bounced.
  if (loadingProfile && !profile) return <FullScreen>{t('Loading…')}</FullScreen>

  if (requireComplete && !isProfileComplete(profile)) {
    return <Navigate to="/complete-profile" replace />
  }
  if (requireActive && profile && !profile.is_active) {
    return <Navigate to="/pending" replace />
  }
  if (requireAdmin && profile?.role !== 'admin') return <Navigate to="/dashboard" replace />

  return <Outlet />
}
