// Auth context (build plan §3). One Supabase auth subscription + one profile fetch
// for the whole app, exposed via useAuth(). useProfile() is a thin accessor over it.
import { createContext, createElement, useCallback, useContext, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'

const AuthContext = createContext(null)

export function AuthProvider({ children }) {
  const [session, setSession] = useState(null)
  const [profile, setProfile] = useState(null)
  // Whether this member is still on a PIN an admin issued. Loaded here rather than
  // in the page that needs it because ProtectedRoute gates every route on it: an
  // admin-issued PIN is a credential two people know, so while it stands the admin
  // can act as that member and nothing done in their name proves they did it.
  const [pinStatus, setPinStatus] = useState(null)
  // If Supabase isn't configured there's nothing to resolve, so we're not "loading".
  const [loading, setLoading] = useState(Boolean(supabase))
  const [loadingProfile, setLoadingProfile] = useState(false)

  const loadProfile = useCallback(async (id) => {
    if (!supabase || !id) {
      setProfile(null)
      setPinStatus(null)
      return
    }
    setLoadingProfile(true)
    const { data, error } = await supabase
      .from('profiles')
      .select(
        'id, full_name, role, is_active, is_superadmin, phone_number, secondary_phone, email, residence, national_id, next_of_kin_name, next_of_kin_phone',
      )
      .eq('id', id)
      .single()
    if (error) {
      console.error('Failed to load profile', error)
      setProfile(null)
    } else {
      setProfile(data)
    }

    // own_pin_status() is scoped to auth.uid() in SQL, so this can only ever ask
    // about the current session. A failure here must not block the app: default to
    // "nothing to change" so a transient error cannot strand everyone on /set-pin.
    const { data: pin, error: pinError } = await supabase.rpc('own_pin_status')
    if (pinError) {
      console.error('Failed to load PIN status', pinError)
      setPinStatus({ hasPin: false, mustChange: false })
    } else {
      const row = Array.isArray(pin) ? pin[0] : pin
      setPinStatus({ hasPin: row?.has_pin === true, mustChange: row?.must_change === true })
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
    // The overseer (041): one admin whose signature is a quorum on its own. The UI
    // reads this only to stop promising a second signature that will never be
    // asked for — the authority itself is enforced in SQL, never here.
    isOverseer: profile?.is_superadmin === true && profile?.is_active === true,
    pinStatus,
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
