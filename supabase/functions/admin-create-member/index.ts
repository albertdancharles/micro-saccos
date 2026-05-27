// admin-create-member — Edge Function (v2 feature). Creates a new member's auth
// account (the handle_new_user trigger then creates the profile) and returns a
// generated temp password for the admin to share. Creating users needs the
// service-role key, so it must run server-side; the caller must be a signed-in admin.
//
// Deploy (no Docker): Supabase Dashboard → Edge Functions → deploy a function named
// "admin-create-member", paste this file, keep "Verify JWT" ON. Or via CLI:
//   npx supabase functions deploy admin-create-member --project-ref <ref>
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

// Temp password without ambiguous chars (0/O/1/l/I), easy to dictate.
const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
function genPassword(len = 10) {
  const bytes = new Uint8Array(len)
  crypto.getRandomValues(bytes)
  return Array.from(bytes, (b) => ALPHABET[b % ALPHABET.length]).join('')
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
  const ANON = Deno.env.get('SUPABASE_ANON_KEY')!
  const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

  const authHeader = req.headers.get('Authorization') ?? ''
  if (!authHeader) return json({ error: 'Missing authorization' }, 401)

  // Verify the caller is an admin using their own JWT (RLS lets them read own profile).
  const userClient = createClient(SUPABASE_URL, ANON, {
    global: { headers: { Authorization: authHeader } },
  })
  const {
    data: { user },
    error: userErr,
  } = await userClient.auth.getUser()
  if (userErr || !user) return json({ error: 'Not authenticated' }, 401)

  const { data: me } = await userClient.from('profiles').select('role').eq('id', user.id).single()
  if (me?.role !== 'admin') return json({ error: 'Not authorized' }, 403)

  let body: { full_name?: string; email?: string; phone_number?: string }
  try {
    body = await req.json()
  } catch {
    return json({ error: 'Invalid JSON body' }, 400)
  }
  const full_name = body.full_name?.trim()
  const email = body.email?.trim().toLowerCase()
  const phone_number = body.phone_number?.trim()
  if (!full_name || !email || !phone_number) {
    return json({ error: 'full_name, email, and phone_number are all required.' }, 400)
  }

  const password = genPassword()
  const admin = createClient(SUPABASE_URL, SERVICE, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
  const { error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name, phone_number },
  })
  if (error) return json({ error: error.message }, 400)

  // Returned to the admin so they can pass the temp credentials on; the new member
  // changes the password on first login.
  return json({ email, password })
})
