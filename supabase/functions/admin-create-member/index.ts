// admin-create-member — Edge Function (v2 feature). Creates a new member's auth
// account (the handle_new_user trigger then creates the profile) and returns a
// generated temp password for the admin to share. Creating users needs the
// service-role key, so it must run server-side; the caller must be a signed-in admin.
//
// Deploy (no Docker): Supabase Dashboard → Edge Functions → deploy a function named
// "admin-create-member", paste this file, keep "Verify JWT" ON. Or via CLI:
//   npx supabase functions deploy admin-create-member --project-ref <ref>
// Set the ALLOWED_ORIGINS secret (comma-separated) to your app origins, e.g.
//   npx supabase secrets set ALLOWED_ORIGINS="https://your-app.vercel.app,http://localhost:5173"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Browser origins permitted to call this function. The admin JWT check below is the
// real authorization gate; the CORS allowlist is defense-in-depth so the endpoint
// can't be invoked from an arbitrary site on a logged-in admin's behalf. If unset
// (e.g. a first deploy before the secret is configured), we fall back to '*' so the
// app keeps working — but production should always set ALLOWED_ORIGINS.
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

// Temp password without ambiguous chars (0/O/1/l/I), easy to dictate.
const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
function genPassword(len = 10) {
  const bytes = new Uint8Array(len)
  crypto.getRandomValues(bytes)
  return Array.from(bytes, (b) => ALPHABET[b % ALPHABET.length]).join('')
}

function json(body: unknown, status = 200, cors: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  const cors = corsHeaders(req.headers.get('Origin'))
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405, cors)

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
  const ANON = Deno.env.get('SUPABASE_ANON_KEY')!
  const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

  const authHeader = req.headers.get('Authorization') ?? ''
  if (!authHeader) return json({ error: 'Missing authorization' }, 401, cors)

  // Verify the caller is an admin using their own JWT (RLS lets them read own profile).
  const userClient = createClient(SUPABASE_URL, ANON, {
    global: { headers: { Authorization: authHeader } },
  })
  const {
    data: { user },
    error: userErr,
  } = await userClient.auth.getUser()
  if (userErr || !user) return json({ error: 'Not authenticated' }, 401, cors)

  const { data: me } = await userClient.from('profiles').select('role').eq('id', user.id).single()
  if (me?.role !== 'admin') return json({ error: 'Not authorized' }, 403, cors)

  let body: {
    full_name?: string
    email?: string
    phone_number?: string
    secondary_phone?: string
    residence?: string
    national_id?: string
    next_of_kin_name?: string
    next_of_kin_phone?: string
  }
  try {
    body = await req.json()
  } catch {
    return json({ error: 'Invalid JSON body' }, 400, cors)
  }
  const full_name = body.full_name?.trim()
  const email = body.email?.trim().toLowerCase()
  const phone_number = body.phone_number?.trim()
  if (!full_name || !email || !phone_number) {
    return json({ error: 'full_name, email, and phone_number are all required.' }, 400, cors)
  }
  // Optional KYC fields, passed through to the profile via the handle_new_user trigger.
  const extra = {
    secondary_phone: body.secondary_phone?.trim() || null,
    residence: body.residence?.trim() || null,
    national_id: body.national_id?.trim() || null,
    next_of_kin_name: body.next_of_kin_name?.trim() || null,
    next_of_kin_phone: body.next_of_kin_phone?.trim() || null,
  }

  const password = genPassword()
  const admin = createClient(SUPABASE_URL, SERVICE, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
  const { data: created, error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name, phone_number, ...extra },
  })
  if (error) return json({ error: error.message }, 400, cors)

  // Admin-added members skip the pending queue: the trigger creates them as
  // is_active=false (self-signup default), so flip them active here. Service role
  // bypasses RLS.
  if (created?.user?.id) {
    await admin.from('profiles').update({ is_active: true }).eq('id', created.user.id)
  }

  // Audit the creation. Service role bypasses RLS, and auth.uid() isn't available
  // in this context, so we pass the caller's id explicitly.
  await admin.from('audit_log').insert({
    actor_id: user.id,
    action: 'create_member',
    target_type: 'profile',
    target_id: created?.user?.id ?? null,
    details: { email, full_name },
  })

  // Returned to the admin so they can pass the temp credentials on; the new member
  // changes the password on first login.
  return json({ email, password }, 200, cors)
})
