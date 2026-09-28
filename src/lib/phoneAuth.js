// Phone + PIN login. The member-facing way in: first name, phone number, and a PIN
// they chose. Email + password still works and is what the admin uses (see auth.js).
//
// Why the PIN exists at all, since the ask was "first name and phone only": both of
// those are known to every member of the group, and full_name is published in-app by
// group_member_directory(), so without a secret the group's phone list would be a
// working credential for every account in it. A member cannot file a loan or payment
// (034), but an impersonated session can still read their dashboard and PII, take
// their login over by changing their phone number, and — as an admin — approve loans
// and record payments. The name and phone say who is claiming to sign in; the PIN is
// the part only they know.
//
// Everything that can decide a login happens in the member-pin-auth Edge Function,
// which holds the service-role key. This file only collects input, does the cheap
// client-side checks so a bad PIN format does not cost a round trip, and exchanges
// the token the function returns for a session. The checks here are a convenience —
// the Edge Function repeats all of them and its answer is the one that counts.
import { supabase } from '../supabaseClient'

function client() {
  if (!supabase) throw new Error('Supabase is not configured (missing env vars).')
  return supabase
}

// Non-2xx from an Edge Function arrives as FunctionsHttpError with the Response
// tucked in .context, so the real message has to be unwrapped. Same shape as
// createMember() in lib/admin.js.
async function unwrap(error, fallback) {
  let message = error?.message
  try {
    const ctx = await error?.context?.json?.()
    if (ctx?.error) message = ctx.error
  } catch {
    /* keep the generic message */
  }
  return new Error(message || fallback)
}

// ---------------------------------------------------------------------------
// Input checks, mirrored from the Edge Function
// ---------------------------------------------------------------------------

// The first word of a full name, lowercased. Matches member_first_name() in 042.
export function firstNameOf(fullName) {
  return String(fullName || '')
    .trim()
    .split(/\s+/)[0]
    .toLowerCase()
}

// Deliberately NOT a copy of normalize_phone_tz(). That function decides which
// stored number a typed number matches, and it is the same definition the unique
// index enforces; a second copy here would be free to drift from it. This only
// answers "could this be a phone number at all", to catch an empty or obviously
// short entry before a round trip.
export function phoneProblem(phone) {
  const digits = String(phone || '').replace(/\D/g, '')
  if (!digits) return 'Enter your phone number.'
  if (digits.length < 9) return 'That phone number looks too short.'
  if (digits.length > 13) return 'That phone number looks too long.'
  return null
}

// Mirrors pinProblem() in the Edge Function. Kept in step by hand; the server copy
// is authoritative, so a drift here shows up as a rejection after submit rather
// than as an accepted weak PIN.
export function pinProblem(pin) {
  const value = String(pin || '')
  if (!/^\d{4,6}$/.test(value)) return 'A PIN must be 4 to 6 digits.'
  if (/^(\d)\1+$/.test(value)) return 'That PIN is too easy to guess — not all the same digit.'
  if ('01234567890'.includes(value) || '09876543210'.includes(value)) {
    return 'That PIN is too easy to guess — not digits in a row.'
  }
  return null
}

// ---------------------------------------------------------------------------
// Sign in
// ---------------------------------------------------------------------------

// Returns { mustChangePin } — true when the PIN used was one an admin issued, which
// the caller should follow with a "choose your own PIN" screen.
//
// Two steps, and the second is the one that creates the session: the function
// returns a single-use magic-link token_hash, and verifyOtp() exchanges it. The
// member's synthetic @umojagroup.app address never reaches the browser.
export async function signInWithPhonePin({ firstName, phone, pin }) {
  const { data, error } = await client().functions.invoke('member-pin-auth', {
    body: {
      action: 'login',
      first_name: String(firstName || '').trim(),
      phone: String(phone || '').trim(),
      pin: String(pin || ''),
    },
  })
  if (error) throw await unwrap(error, 'Could not sign you in.')
  if (!data?.token_hash) throw new Error('Could not sign you in.')

  const { error: otpError } = await client().auth.verifyOtp({
    token_hash: data.token_hash,
    type: 'magiclink',
  })
  if (otpError) throw otpError

  return { mustChangePin: data.must_change_pin === true }
}

// ---------------------------------------------------------------------------
// Managing a PIN
// ---------------------------------------------------------------------------

// Does the signed-in member have a PIN, and was it one an admin issued? Scoped to
// auth.uid() in SQL, so it cannot be asked about anyone else.
export async function ownPinStatus() {
  const { data, error } = await client().rpc('own_pin_status')
  if (error) throw error
  const row = Array.isArray(data) ? data[0] : data
  return { hasPin: row?.has_pin === true, mustChange: row?.must_change === true }
}

// The member chooses their own PIN. `currentPin` is required only when they already
// have one they chose themselves — replacing an admin-issued PIN does not ask for
// it, since the session already proves they were given it.
export async function setOwnPin({ pin, currentPin }) {
  const problem = pinProblem(pin)
  if (problem) throw new Error(problem)

  const { error } = await client().functions.invoke('member-pin-auth', {
    body: {
      action: 'set_pin',
      pin: String(pin),
      ...(currentPin ? { current_pin: String(currentPin) } : {}),
    },
  })
  if (error) throw await unwrap(error, 'Could not save your PIN.')
}

// Admin action: issue a fresh handover PIN for a member who cannot sign in. Returns
// { pin, first_name } for the admin to read out — shown once and never retrievable,
// the same contract as the temp password from admin-create-member.
export async function resetMemberPin(memberId) {
  const { data, error } = await client().functions.invoke('member-pin-auth', {
    body: { action: 'reset_pin', member_id: memberId },
  })
  if (error) throw await unwrap(error, 'Could not reset the PIN.')
  return data
}

// Admin view of who can actually sign in: whether a PIN is set, whether it is still
// an admin-issued one, and whether the member is locked out right now.
export async function getMemberPinOverview() {
  const { data, error } = await client().rpc('member_pin_overview')
  if (error) throw error
  return data || []
}
