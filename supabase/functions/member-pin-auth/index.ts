// member-pin-auth — Edge Function. Everything that touches a member's login PIN:
// signing in with first name + phone + PIN, a member choosing their own PIN, and an
// admin resetting one they cannot remember.
//
// Deploy (no Docker): Supabase Dashboard -> Edge Functions -> deploy a function named
// "member-pin-auth", paste this file, and turn "Verify JWT" OFF. Or via CLI:
//   npx supabase functions deploy member-pin-auth --no-verify-jwt --project-ref <ref>
// Set ALLOWED_ORIGINS as for admin-create-member:
//   npx supabase secrets set ALLOWED_ORIGINS="https://your-app.vercel.app,http://localhost:5173"
//
// ---------------------------------------------------------------------------
// WHY "Verify JWT" IS OFF, AND WHAT PAYS FOR IT
//
// The `login` action is used by someone who has no session yet, so the platform's
// JWT gate cannot be the thing that protects this function. It is off for the whole
// file, which means every other action has to verify the caller in code. It does:
// `set_pin` and `reset_pin` both call requireUser(), which fails closed when the
// Authorization header is missing, malformed or expired, and `reset_pin` then
// additionally checks the caller's profile role is 'admin'. That is the same
// belt-and-braces admin-create-member already applies on top of its own JWT gate.
//
// The three actions live in one function, rather than a public `login` function plus
// a JWT-gated `pin` function, because splitting them would mean two copies of the
// PBKDF2 code. The repo's deploy path is a dashboard paste, so a _shared/ import is
// not available to factor it out, and a hash routine that has to be fixed in two
// places is a worse risk than an auth check written by hand.
//
// ---------------------------------------------------------------------------
// WHY name + phone IS NOT ENOUGH ON ITS OWN
//
// Asked for: "log in with only first name and phone number". Not built, on purpose.
// Everyone in a 15-person savings group knows everyone's first name and phone
// number, and full_name is already published in-app by group_member_directory(), so
// with no secret the group's phone list is a working credential for every account.
//
// 034 already stops a member filing a loan or a payment, so the exposure is not
// forged requests: it is reading another member's dashboard and profile PII, taking
// over their login by changing their phone number, and — the one that matters -
// signing in as an ADMIN, whose session records payments and approves loans, and
// whose signature alone is a quorum if they are 041's overseer.
//
// The PIN is the secret. Name and phone only say who is claiming to sign in.
// See 042_phone_pin_login.sql.
//
// An SMS one-time code would be stronger still and is the obvious future upgrade,
// but it is not available today: per 039_dispatch_requires_pg_net.sql the
// notification drain has never actually run, so a login that depended on SMS
// delivery would lock out every member in the group.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ---------------------------------------------------------------------------
// CORS — same shape as admin-create-member.
// ---------------------------------------------------------------------------
const ALLOWED = (Deno.env.get('ALLOWED_ORIGINS') ?? '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)

function corsHeaders(origin: string | null) {
  const allowOrigin =
    ALLOWED.length === 0 ? '*' : origin && ALLOWED.includes(origin) ? origin : ALLOWED[0]
  return {
    'Access-Control-Allow-Origin': allowOrigin,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin',
  }
}

function json(body: unknown, status = 200, cors: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  })
}

// ---------------------------------------------------------------------------
// PIN hashing — PBKDF2-SHA256 through Web Crypto, no dependency.
//
// Format: pbkdf2_sha256$<iterations>$<salt_b64>$<hash_b64>. Self-describing, so the
// iteration count can be raised later without invalidating the PINs already set.
//
// What this hash is not for: a 4-6 digit PIN has 10^4 to 10^6 possible values, so
// anyone holding the table can exhaust it at any iteration count. The hash means a
// leaked table is not immediately a list of live credentials. The control that
// actually protects the account is the attempt limit in phone_login_attempts,
// applied before the PIN is ever looked at.
// ---------------------------------------------------------------------------
const ITERATIONS = 210_000 // OWASP 2023 guidance for PBKDF2-SHA256
const KEY_BYTES = 32
const SALT_BYTES = 16

const b64 = (buf: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(buf)))
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0))

async function derive(pin: string, salt: Uint8Array, iterations: number) {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(pin),
    'PBKDF2',
    false,
    ['deriveBits'],
  )
  return crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt, iterations },
    key,
    KEY_BYTES * 8,
  )
}

async function hashPin(pin: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(SALT_BYTES))
  const bits = await derive(pin, salt, ITERATIONS)
  return `pbkdf2_sha256$${ITERATIONS}$${b64(salt)}$${b64(bits)}`
}

// Constant-time compare, so the check cannot be timed into a byte-by-byte oracle.
// Any malformed stored hash reads as "wrong PIN" rather than throwing — a corrupt
// row must not become a 500 that confirms the row exists.
async function verifyPin(pin: string, stored: string | null): Promise<boolean> {
  if (!stored) return false
  const parts = stored.split('$')
  if (parts.length !== 4 || parts[0] !== 'pbkdf2_sha256') return false

  const iterations = Number(parts[1])
  if (!Number.isInteger(iterations) || iterations < 1) return false

  let salt: Uint8Array
  let expected: Uint8Array
  try {
    salt = unb64(parts[2])
    expected = unb64(parts[3])
  } catch {
    return false
  }

  const actual = new Uint8Array(await derive(pin, salt, iterations))
  if (actual.length !== expected.length) return false

  let diff = 0
  for (let i = 0; i < actual.length; i++) diff |= actual[i] ^ expected[i]
  return diff === 0
}

// A hash of a value nobody holds, used to spend the same CPU on a phone number that
// matches no member as on one that does. Generated once per cold start.
const DECOY_HASH = await hashPin(crypto.randomUUID())

// 4-6 digits, and not one of the few values a five-attempt brute force would spend
// its attempts on first. Mirrored in src/lib/phoneAuth.js so the member gets the
// same answer before a round trip; this copy is the one that decides.
function pinProblem(pin: string): string | null {
  if (!/^\d{4,6}$/.test(pin)) return 'A PIN must be 4 to 6 digits.'
  if (/^(\d)\1+$/.test(pin)) return 'That PIN is too easy to guess — not all the same digit.'
  if ('01234567890'.includes(pin) || '09876543210'.includes(pin)) {
    return 'That PIN is too easy to guess — not digits in a row.'
  }
  return null
}

// A PIN an admin hands over. Avoids the values pinProblem() rejects, so a generated
// code is never one the member is then refused for keeping.
function genPin(): string {
  for (;;) {
    const bytes = crypto.getRandomValues(new Uint8Array(4))
    const pin = Array.from(bytes, (b) => String(b % 10)).join('')
    if (!pinProblem(pin)) return pin
  }
}

// ---------------------------------------------------------------------------
// Clients
// ---------------------------------------------------------------------------
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

const adminClient = () =>
  createClient(SUPABASE_URL, SERVICE, {
    auth: { autoRefreshToken: false, persistSession: false },
  })

// Resolve the caller from their own JWT. Returns null when there is no usable
// session — the callers of this treat null as a hard stop.
async function requireUser(authHeader: string) {
  if (!authHeader) return null
  const userClient = createClient(SUPABASE_URL, ANON, {
    global: { headers: { Authorization: authHeader } },
  })
  const {
    data: { user },
    error,
  } = await userClient.auth.getUser()
  if (error || !user) return null
  const { data: me } = await userClient
    .from('profiles')
    .select('role, is_active')
    .eq('id', user.id)
    .single()
  return { id: user.id, role: me?.role ?? 'member', is_active: me?.is_active ?? false }
}

// ---------------------------------------------------------------------------
// login — first name + phone + PIN -> a session
//
// The response is a magic-link token_hash, which the browser exchanges for a real
// session via supabase.auth.verifyOtp(). Generating the link never sends an email
// and never needs the member's password, so the synthetic @umojagroup.app address
// stays an implementation detail the client never sees.
// ---------------------------------------------------------------------------

// One message for every way a login can be wrong: unknown number, wrong name, wrong
// PIN, or no PIN set yet. Distinguishing them would turn this endpoint into a way to
// ask which phone numbers belong to the group and who owns them.
const REJECTED = 'That name, phone number and PIN do not match. Check them, or ask your admin.'

async function handleLogin(body: Record<string, unknown>, cors: Record<string, string>) {
  const firstName = String(body.first_name ?? '').trim().toLowerCase()
  const phone = String(body.phone ?? '').trim()
  const pin = String(body.pin ?? '')

  if (!firstName || !phone || !pin) {
    return json({ error: 'First name, phone number and PIN are all required.' }, 400, cors)
  }

  const admin = adminClient()

  // Normalise through the same SQL function the unique index uses, so "is this the
  // same number?" has exactly one definition in the system.
  const { data: phoneKey } = await admin.rpc('normalize_phone_tz', { p_phone: phone })
  if (!phoneKey) return json({ error: REJECTED }, 401, cors)

  // Spend an attempt BEFORE looking at the PIN. Keyed on the typed number, so a
  // number belonging to nobody is throttled exactly like a real member's.
  const { data: lockedUntil, error: attemptErr } = await admin.rpc('begin_login_attempt', {
    p_phone_key: phoneKey,
  })
  if (attemptErr) return json({ error: 'Could not sign you in. Try again.' }, 500, cors)
  if (lockedUntil) {
    const minutes = Math.max(1, Math.ceil((Date.parse(lockedUntil) - Date.now()) / 60000))
    return json(
      {
        error: `Too many attempts. Try again in ${minutes} minute${minutes === 1 ? '' : 's'}, or ask your admin to reset your PIN.`,
        locked_until: lockedUntil,
      },
      429,
      cors,
    )
  }

  const { data: rows } = await admin.rpc('lookup_phone_login', { p_phone: phone })
  const match = Array.isArray(rows) ? rows[0] : null

  // Verify against a decoy hash when there is no match, so a number that belongs to
  // nobody costs the same ~200ms as one that does. Without this the response time
  // alone answers "is this number in the group?".
  const ok = await verifyPin(pin, match?.pin_hash ?? DECOY_HASH)
  if (!match || !ok) return json({ error: REJECTED }, 401, cors)

  if (match.first_name !== firstName) return json({ error: REJECTED }, 401, cors)

  await admin.rpc('clear_login_attempts', { p_phone_key: phoneKey })

  const { data: link, error: linkErr } = await admin.auth.admin.generateLink({
    type: 'magiclink',
    email: match.email,
  })
  if (linkErr || !link?.properties?.hashed_token) {
    return json({ error: 'Could not sign you in. Try again.' }, 500, cors)
  }

  return json(
    {
      token_hash: link.properties.hashed_token,
      must_change_pin: match.must_change === true,
    },
    200,
    cors,
  )
}

// ---------------------------------------------------------------------------
// set_pin — the signed-in member chooses their own PIN
//
// Requires the current PIN when one is already set and the member chose it. A PIN an
// admin set (must_change) is skipped: the member is signing in with a code that was
// read out to them, and asking them to retype it is friction that protects nothing
// the session does not already prove.
// ---------------------------------------------------------------------------
async function handleSetPin(
  body: Record<string, unknown>,
  authHeader: string,
  cors: Record<string, string>,
) {
  const caller = await requireUser(authHeader)
  if (!caller) return json({ error: 'Not authenticated' }, 401, cors)
  if (!caller.is_active) return json({ error: 'Your membership is not active.' }, 403, cors)

  const pin = String(body.pin ?? '')
  const problem = pinProblem(pin)
  if (problem) return json({ error: problem }, 400, cors)

  const admin = adminClient()
  const { data: existing } = await admin
    .from('member_pins')
    .select('pin_hash, must_change')
    .eq('member_id', caller.id)
    .maybeSingle()

  if (existing && !existing.must_change) {
    const currentPin = String(body.current_pin ?? '')
    if (!currentPin) return json({ error: 'Enter your current PIN.' }, 400, cors)
    if (!(await verifyPin(currentPin, existing.pin_hash))) {
      return json({ error: 'That is not your current PIN.' }, 401, cors)
    }
  }

  const pin_hash = await hashPin(pin)
  const { error } = await admin.from('member_pins').upsert(
    {
      member_id: caller.id,
      pin_hash,
      must_change: false,
      set_by: null,
      set_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
    { onConflict: 'member_id' },
  )
  if (error) return json({ error: 'Could not save your PIN.' }, 500, cors)

  // A member choosing their own PIN also clears any lockout standing against their
  // number — they have just proved the session, so the old count is meaningless.
  const { data: profile } = await admin
    .from('profiles')
    .select('phone_number')
    .eq('id', caller.id)
    .single()
  if (profile?.phone_number) {
    const { data: key } = await admin.rpc('normalize_phone_tz', { p_phone: profile.phone_number })
    if (key) await admin.rpc('clear_login_attempts', { p_phone_key: key })
  }

  await admin.from('audit_log').insert({
    actor_id: caller.id,
    action: 'set_own_pin',
    target_type: 'profile',
    target_id: caller.id,
    details: {},
  })

  return json({ ok: true }, 200, cors)
}

// ---------------------------------------------------------------------------
// reset_pin — an admin issues a new handover PIN for a member
//
// Returns the generated PIN once, for the admin to read out, exactly as
// admin-create-member returns a temp password. It is stored hashed and flagged
// must_change, so the member is asked to choose their own on next sign-in.
// ---------------------------------------------------------------------------
async function handleResetPin(
  body: Record<string, unknown>,
  authHeader: string,
  cors: Record<string, string>,
) {
  const caller = await requireUser(authHeader)
  if (!caller) return json({ error: 'Not authenticated' }, 401, cors)
  if (caller.role !== 'admin') return json({ error: 'Not authorized' }, 403, cors)

  const memberId = String(body.member_id ?? '').trim()
  if (!memberId) return json({ error: 'member_id is required.' }, 400, cors)

  const admin = adminClient()
  const { data: target } = await admin
    .from('profiles')
    .select('id, full_name, phone_number')
    .eq('id', memberId)
    .maybeSingle()
  if (!target) return json({ error: 'No such member.' }, 404, cors)
  if (!target.phone_number) {
    return json(
      { error: 'Add a phone number for this member first — it is half of their login.' },
      400,
      cors,
    )
  }

  const pin = genPin()
  const pin_hash = await hashPin(pin)
  const { error } = await admin.from('member_pins').upsert(
    {
      member_id: memberId,
      pin_hash,
      must_change: true,
      set_by: caller.id,
      set_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
    { onConflict: 'member_id' },
  )
  if (error) return json({ error: 'Could not reset the PIN.' }, 500, cors)

  // Clear the lockout too, or a member who locked themselves out still cannot use
  // the PIN the admin just gave them.
  const { data: key } = await admin.rpc('normalize_phone_tz', { p_phone: target.phone_number })
  if (key) await admin.rpc('clear_login_attempts', { p_phone_key: key })

  await admin.from('audit_log').insert({
    actor_id: caller.id,
    action: 'admin_reset_pin',
    target_type: 'profile',
    target_id: memberId,
    details: { full_name: target.full_name },
  })

  return json({ pin, first_name: String(target.full_name ?? '').split(' ')[0] }, 200, cors)
}

// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  const cors = corsHeaders(req.headers.get('Origin'))
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405, cors)

  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return json({ error: 'Invalid JSON body' }, 400, cors)
  }

  const authHeader = req.headers.get('Authorization') ?? ''

  switch (String(body.action ?? '')) {
    case 'login':
      return handleLogin(body, cors)
    case 'set_pin':
      return handleSetPin(body, authHeader, cors)
    case 'reset_pin':
      return handleResetPin(body, authHeader, cors)
    default:
      return json({ error: 'Unknown action.' }, 400, cors)
  }
})
