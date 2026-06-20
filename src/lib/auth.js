// Auth helpers (build plan §3, §9; v3 self-registration). Thin wrappers over
// Supabase Auth so pages don't touch the client directly. v1 methods: email +
// password and Google OAuth (phone-OTP deferred).
import { supabase } from '../supabaseClient'

function client() {
  if (!supabase) throw new Error('Supabase is not configured (missing env vars).')
  return supabase
}

export async function signIn(email, password) {
  const { data, error } = await client().auth.signInWithPassword({ email, password })
  if (error) throw error
  return data
}

// Self-service registration. Profile fields ride along in user_metadata; the
// handle_new_user trigger creates a PENDING profile (is_active=false) from them.
// With "Confirm email" ON in Supabase, no session is returned until the user
// confirms — callers should show a "check your email" notice.
export async function signUp(email, password, profileFields = {}) {
  const emailRedirectTo = `${window.location.origin}/login`
  const { data, error } = await client().auth.signUp({
    email,
    password,
    options: { data: profileFields, emailRedirectTo },
  })
  if (error) throw error
  return data
}

// Google OAuth. Redirects to Google and back to the app root, where the route
// gate sends the user to /complete-profile (new) or /pending.
export async function signInWithGoogle() {
  const redirectTo = `${window.location.origin}/`
  const { data, error } = await client().auth.signInWithOAuth({
    provider: 'google',
    options: { redirectTo },
  })
  if (error) throw error
  return data
}

// Member edits their own profile (KYC) via the SECURITY DEFINER RPC, which can
// never change role/is_active. Used by /complete-profile and the Profile page.
export async function updateOwnProfile(fields) {
  const { error } = await client().rpc('update_own_profile', {
    p_full_name: fields.full_name ?? '',
    p_phone_number: fields.phone_number ?? '',
    p_secondary_phone: fields.secondary_phone ?? '',
    p_residence: fields.residence ?? '',
    p_national_id: fields.national_id ?? '',
    p_next_of_kin_name: fields.next_of_kin_name ?? '',
    p_next_of_kin_phone: fields.next_of_kin_phone ?? '',
  })
  if (error) throw error
}

// The fields a member must supply before they can use the app. Google sign-ups
// arrive with only name + email, so they're routed to /complete-profile until
// these are filled. (secondary_phone is optional.)
export const REQUIRED_PROFILE_FIELDS = [
  'full_name',
  'phone_number',
  'residence',
  'national_id',
  'next_of_kin_name',
  'next_of_kin_phone',
]

export function isProfileComplete(profile) {
  if (!profile) return false
  return REQUIRED_PROFILE_FIELDS.every((f) => {
    const v = profile[f]
    return typeof v === 'string' ? v.trim() !== '' : Boolean(v)
  })
}

export async function signOut() {
  const { error } = await client().auth.signOut()
  if (error) throw error
}

// Sends the password-reset email. The link lands on /update-password, which reads
// the recovery session and lets the user set a new password. Note: members with
// synthetic @umojagroup.app logins have no real inbox, so in practice this is for
// the admin; member resets are handled by the admin.
export async function sendPasswordReset(email) {
  const redirectTo = `${window.location.origin}/update-password`
  const { error } = await client().auth.resetPasswordForEmail(email, { redirectTo })
  if (error) throw error
}

export async function updatePassword(newPassword) {
  const { error } = await client().auth.updateUser({ password: newPassword })
  if (error) throw error
}
