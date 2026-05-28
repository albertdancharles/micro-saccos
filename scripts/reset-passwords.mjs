// Rotate temp passwords for ALL existing auth users (mirrors the seed pattern):
// strong random temp passwords are generated, applied via the admin API, and
// printed once so the admin can distribute them. Destructive — invalidates any
// existing passwords — so it requires `--yes` to actually execute. Without the
// flag, it just lists the users it would touch and exits.
//
// Run:
//   $env:SUPABASE_URL="https://<your-ref>.supabase.co"
//   $env:SUPABASE_SERVICE_ROLE_KEY="<service_role secret>"
//   npm run reset-passwords            # dry run — shows who would be rotated
//   npm run reset-passwords -- --yes   # actually rotate
import { createClient } from '@supabase/supabase-js'
import { randomInt } from 'node:crypto'

const url = process.env.SUPABASE_URL
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY

if (!url || !serviceKey) {
  console.error('Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY first (see header).')
  process.exit(1)
}

const confirmed = process.argv.slice(2).includes('--yes')

const supabase = createClient(url, serviceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
})

// Avoids ambiguous chars (0/O/1/l/I) so the temp password is easy to dictate.
const PW_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
function genPassword(len = 10) {
  let s = ''
  for (let i = 0; i < len; i++) s += PW_ALPHABET[randomInt(PW_ALPHABET.length)]
  return s
}

const { data, error } = await supabase.auth.admin.listUsers({ perPage: 1000 })
if (error) {
  console.error('Failed to list users:', error.message)
  process.exit(1)
}
const users = (data?.users ?? []).filter((u) => u.email)
if (!users.length) {
  console.error('No users found. Nothing to do.')
  process.exit(0)
}

if (!confirmed) {
  console.log(`Would rotate passwords for ${users.length} user(s):`)
  for (const u of users) console.log(`  - ${u.email}`)
  console.log('\nRe-run with --yes to actually rotate:')
  console.log('  npm run reset-passwords -- --yes')
  process.exit(0)
}

const rotated = []
for (const u of users) {
  const password = genPassword()
  const { error: upErr } = await supabase.auth.admin.updateUserById(u.id, { password })
  if (upErr) {
    console.error(`✗ ${u.email}: ${upErr.message}`)
    continue
  }
  console.log(`✓ rotated ${u.email}`)
  rotated.push({ email: u.email, password })
}

if (rotated.length) {
  console.log('\n=== New temp passwords (distribute securely; members change on first login) ===')
  for (const r of rotated) console.log(`${r.email}\t${r.password}`)
  console.log('==========================================================================')
}
console.log(`\nDone. Rotated ${rotated.length} of ${users.length}.`)
