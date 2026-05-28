// Promote one or more existing members to admin. Mirrors the seed/reset-passwords
// pattern: service-role key via shell env, lookup by email through the admin API,
// then UPDATE profiles SET role = 'admin'. Idempotent — re-running for someone
// already admin is harmless.
//
// Run:
//   $env:SUPABASE_URL="https://<your-ref>.supabase.co"
//   $env:SUPABASE_SERVICE_ROLE_KEY="<service_role secret>"
//   npm run promote-admin -- email1@example.com email2@example.com
import { createClient } from '@supabase/supabase-js'

const url = process.env.SUPABASE_URL
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY

if (!url || !serviceKey) {
  console.error('Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY first (see header).')
  process.exit(1)
}

const emails = process.argv.slice(2).filter(Boolean)
if (!emails.length) {
  console.error('Usage: npm run promote-admin -- email1@example.com email2@example.com [...]')
  process.exit(1)
}

const supabase = createClient(url, serviceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
})

const { data, error } = await supabase.auth.admin.listUsers({ perPage: 1000 })
if (error) {
  console.error('Failed to list users:', error.message)
  process.exit(1)
}
const usersByEmail = new Map(
  (data?.users ?? []).filter((u) => u.email).map((u) => [u.email.toLowerCase(), u]),
)

for (const raw of emails) {
  const email = raw.toLowerCase()
  const user = usersByEmail.get(email)
  if (!user) {
    console.error(`✗ ${raw}: no account with that email`)
    continue
  }
  const { error: upErr } = await supabase
    .from('profiles')
    .update({ role: 'admin' })
    .eq('id', user.id)
  if (upErr) {
    console.error(`✗ ${raw}: ${upErr.message}`)
    continue
  }
  console.log(`✓ promoted ${raw} to admin`)
}

console.log('\nDone.')
