// Route guard (build plan §3, item 24). Redirects unauthenticated users to /login
// and keeps members off the admin routes.
//
// The self-registration gates (incomplete profile → /complete-profile, awaiting
// approval → /pending) are gone with the pages they served: accounts are created by
// an admin, already complete and already active, so there is no longer a state
// between "signed in" and "full member" to hold anyone in.
//
// A deactivated member gets a terminal screen, NOT a redirect to /login. Login
// bounces any live session straight back to "/" (Login.jsx), so redirecting an
// inactive-but-signed-in user there is an infinite loop. Signing out from here is
// the only way off this screen, which is also the honest thing to show someone
// whose membership has ended.
import { Navigate, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { signOut } from '../lib/auth'

function FullScreen({ children }) {
  return (
    <div className="min-h-dvh flex items-center justify-center text-gray-500">
      {children}
    </div>
  )
}

function Deactivated() {
  const { t } = useLanguage()
  const navigate = useNavigate()
  return (
    <div className="min-h-dvh flex items-center justify-center px-6">
      <div className="max-w-sm text-center space-y-4">
        <p className="text-slate-900 font-medium">{t('Your membership is not active.')}</p>
        <p className="text-sm text-slate-500">
          {t('Speak to your group admin if you think this is a mistake.')}
        </p>
        <button
          onClick={async () => {
            await signOut()
            navigate('/login', { replace: true })
          }}
          className="btn-secondary"
        >
          {t('Sign out')}
        </button>
      </div>
    </div>
  )
}

export default function ProtectedRoute({ requireAdmin = false }) {
  const { session, profile, pinStatus, loading, loadingProfile } = useAuth()
  const { t } = useLanguage()
  const location = useLocation()

  if (loading) return <FullScreen>{t('Loading…')}</FullScreen>
  if (!session) return <Navigate to="/login" replace />

  // Hold rendering until we know the profile, so a member isn't briefly bounced.
  if (loadingProfile && !profile) return <FullScreen>{t('Loading…')}</FullScreen>

  // Deactivated: nothing here is theirs to see any more. The database agrees —
  // 034 scoped the group-wide read policies to is_active_member(), so even the
  // requests this screen prevents would come back empty.
  if (profile && !profile.is_active) return <Deactivated />

  // Still on the PIN an admin read out to them. Held here until they choose their
  // own, because until they do, two people can sign in as this member — and one of
  // them can read their PII and change the phone number their login depends on.
  // Worse when the member is themselves an admin: 008 wants a second signature from
  // a second person, and a PIN the first person knows is not that.
  //
  // The /set-pin exemption is what stops this being a redirect loop.
  if (pinStatus?.mustChange && location.pathname !== '/set-pin') {
    return <Navigate to="/set-pin" replace />
  }

  if (requireAdmin && profile?.role !== 'admin') return <Navigate to="/dashboard" replace />

  return <Outlet />
}
