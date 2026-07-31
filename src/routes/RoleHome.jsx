// Role-based landing (build plan §9, item 24): admins → /admin, members → /dashboard.
// Mounted at "/" inside the protected tree, so it always has a session.
import { Navigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'

export default function RoleHome() {
  const { profile, loadingProfile } = useAuth()
  const { t } = useLanguage()

  if (loadingProfile && !profile) {
    return (
      <div className="min-h-dvh flex items-center justify-center text-gray-500">
        {t('Loading…')}
      </div>
    )
  }
  return <Navigate to={profile?.role === 'admin' ? '/admin' : '/dashboard'} replace />
}
