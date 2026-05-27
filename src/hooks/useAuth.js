// Auth context (build plan §3). One Supabase auth subscription + one profile fetch
// for the whole app, exposed via useAuth(). useProfile() is a thin accessor over it.
import { createContext, createElement, useCallback, useContext, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'

const AuthContext = createContext(null)

export function AuthProvider({ children }) {
  const [session, setSession] = useState(null)
  const [profile, setProfile] = useState(null)
  // If Supabase isn't configured there's nothing to resolve, so we're not "loading".
  const [loading, setLoading] = useState(Boolean(supabase))
  const [loadingProfile, setLoadingProfile] = useState(false)

  const loadProfile = useCallback(async (id) => {
    if (!supabase || !id) {
      setProfile(null)
      return
    }
    setLoadingProfile(true)
    const { data, error } = await supabase
      .from('profiles')
      .select('id, full_name, role, is_active, phone_number')
      .eq('id', id)
      .single()
    if (error) {
      console.error('Failed to load profile', error)
      setProfile(null)
    } else {
      setProfile(data)
    }
    setLoadingProfile(false)
  }, [])

  // Resolve the session, then keep session + profile in sync with sign-in/out and
  // password-recovery. All state is set inside async callbacks (never synchronously
  // in the effect body) so there are no cascading renders.
  useEffect(() => {
    if (!supabase) return
    let active = true

    async function applySession(nextSession) {
      if (!active) return
      setSession(nextSession)
      await loadProfile(nextSession?.user?.id ?? null)
    }

    supabase.auth.getSession().then(({ data }) => {
      if (!active) return
      applySession(data.session).finally(() => {
        if (active) setLoading(false)
      })
    })

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      applySession(nextSession)
    })

    return () => {
      active = false
      subscription.unsubscribe()
    }
  }, [loadProfile])

  const value = {
    session,
    user: session?.user ?? null,
    profile,
    loading,
    loadingProfile,
    refreshProfile: () => loadProfile(session?.user?.id ?? null),
  }

  return createElement(AuthContext.Provider, { value }, children)
}

export function useAuth() {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used within <AuthProvider>')
  return ctx
}
