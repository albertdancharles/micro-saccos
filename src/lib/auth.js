// Auth helpers. Thin wrappers over Supabase Auth so pages don't touch the client
// directly. Email + password only.
//
// signUp, signInWithGoogle, updateOwnProfile, REQUIRED_PROFILE_FIELDS and
// isProfileComplete are GONE, with the self-registration flow they served. Accounts
// are created by an admin through the admin-create-member Edge Function, already
// complete and already active, so there is no signup, no Google entry point, and no
// "finish your profile" state to detect. Deleting them rather than leaving them
// unused matters here: a live signUp() helper is a working way into a flow the
// group has decided not to have.
//
// Turning off the pages is only half of it — email signups must also be disabled in
// the Supabase Auth dashboard, or the endpoint stays open with nothing pointing at it.
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
