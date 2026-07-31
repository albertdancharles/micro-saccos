// Admin-only "view member dashboard" wrapper. Reads :memberId from the URL,
// fetches the target's profile, and renders MemberDashboard in view mode.
// Admins are blocked from viewing OTHER admins' dashboards; trying it
// redirects to /admin with no data leaked.
import { useEffect, useState } from 'react'
import { Navigate, useParams } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { supabase } from '../supabaseClient'
import MemberDashboard from './MemberDashboard'

export default function ViewMember() {
  const { memberId } = useParams()
  const { user } = useAuth()
  const { t } = useLanguage()
  const [profile, setProfile] = useState(null)
  const [loading, setLoading] = useState(true)
  const [blocked, setBlocked] = useState(false)

  useEffect(() => {
    if (!supabase || !memberId) return
    let cancelled = false
    supabase
      .from('profiles')
      .select('id, full_name, role')
      .eq('id', memberId)
      .single()
      .then(({ data, error }) => {
        if (cancelled) return
        if (error || !data) {
          setBlocked(true)
        } else if (data.role === 'admin' && data.id !== user?.id) {
          // Admins can't view another admin's dashboard, even directly via URL.
          setBlocked(true)
        } else {
          setProfile(data)
        }
        setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [memberId, user?.id])

  if (blocked) return <Navigate to="/admin" replace />
  if (loading) {
    return (
      <div className="min-h-dvh flex items-center justify-center text-slate-500 bg-[var(--color-app-bg)]">
        {t('Loading…')}
      </div>
    )
  }
  return <MemberDashboard viewAs={memberId} viewedName={profile?.full_name} />
}
