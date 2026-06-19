// Route guard (build plan §3, item 24). Redirects unauthenticated users to /login
// and gates admin-only routes. Wraps child routes via <Outlet />.
import { Navigate, Outlet } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'

function FullScreen({ children }) {
  return (
    <div className="min-h-screen flex items-center justify-center text-gray-500">
      {children}
    </div>
  )
}

export default function ProtectedRoute({ requireAdmin = false }) {
  const { session, profile, loading, loadingProfile } = useAuth()
  const { t } = useLanguage()

  if (loading) return <FullScreen>{t('Loading…')}</FullScreen>
  if (!session) return <Navigate to="/login" replace />

  // Hold rendering until we know the role, so an admin isn't briefly bounced.
  if (loadingProfile && !profile) return <FullScreen>{t('Loading…')}</FullScreen>
  if (requireAdmin && profile?.role !== 'admin') return <Navigate to="/dashboard" replace />

  return <Outlet />
}
