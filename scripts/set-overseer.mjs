// Hand the overseer flag to one member, or take it back. Mirrors the
// promote-admin pattern: service-role key via shell env, lookup by email through
// the admin API, then write profiles.is_superadmin.
//
// This script is the ONLY way to move the flag. protect_overseer() (migration
// 041) refuses any change to is_superadmin that arrives with an auth.uid() set,
// which is every request from the app itself — so no admin, and no number of
// admins, can grant or strip it from inside Micro-SACCOS.
//
// Run:
//   $env:SUPABASE_URL="https://<your-ref>.supabase.co"
//   $env:SUPABASE_SERVICE_ROLE_KEY="<service_role secret>"
//   npm run set-overseer -- albertdancharles@gmail.com
//
// To stand the overseer down (the recovery path — do this before demoting,
// deactivating or removing that member, all of which 041 otherwise refuses):
//   npm run set-overseer -- --clear
import { createClient } from '@supabase/supabase-js'

const url = process.env.SUPABASE_URL
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY

if (!url || !serviceKey) {
  console.error('Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY first (see header).')
  process.exit(1)
}

const args = process.argv.slice(2).filter(Boolean)
const clearing = args.includes('--clear')
const emails = args.filter((a) => a !== '--clear')

if (!clearing && emails.length !== 1) {
  console.error('Usage: npm run set-overseer -- <email>   |   npm run set-overseer -- --clear')
  process.exit(1)
}

const supabase = createClient(url, serviceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
})

// Who holds it now, so the change is always reported against what was there.
const { data: held, error: heldErr } = await supabase
  .from('profiles')
  .select('id, full_name, role')
  .eq('is_superadmin', true)

if (heldErr) {
  console.error('Could not read the current overseer:', heldErr.message)
  process.exit(1)
}
const current = held?.[0] ?? null
console.log(current ? `Current overseer: ${current.full_name}` : 'Current overseer: none')

if (clearing) {
  if (!current) {
    console.log('Nothing to clear.')
    process.exit(0)
  }
  const { error } = await supabase
    .from('profiles')
    .update({ is_superadmin: false })
    .eq('id', current.id)
  if (error) {
    console.error(`✗ ${error.message}`)
    process.exit(1)
  }
  console.log(`✓ ${current.full_name} is no longer the overseer — an ordinary admin again.`)
  console.log('  Two signatures apply to them from the next action onward.')
  process.exit(0)
}

const email = emails[0].toLowerCase()

const { data, error } = await supabase.auth.admin.listUsers({ perPage: 1000 })
if (error) {
  console.error('Failed to list users:', error.message)
  process.exit(1)
}
const user = (data?.users ?? []).find((u) => u.email?.toLowerCase() === email)
if (!user) {
  console.error(`✗ ${emails[0]}: no account with that email`)
  process.exit(1)
}

// one_overseer_only is a unique index, so the sitting overseer stands down first.
if (current && current.id !== user.id) {
  const { error: clearErr } = await supabase
    .from('profiles')
    .update({ is_superadmin: false })
    .eq('id', current.id)
  if (clearErr) {
    console.error(`✗ could not stand down ${current.full_name}: ${clearErr.message}`)
    process.exit(1)
  }
  console.log(`  ${current.full_name} stood down.`)
}

// role = 'admin' first: is_admin() is what every RPC and RLS policy gates on, and
// 041 refuses to change the role of a profile that already holds the flag.
const { error: roleErr } = await supabase
  .from('profiles')
  .update({ role: 'admin' })
  .eq('id', user.id)
if (roleErr) {
  console.error(`✗ could not make ${emails[0]} an admin: ${roleErr.message}`)
  process.exit(1)
}

const { error: flagErr } = await supabase
  .from('profiles')
  .update({ is_superadmin: true })
  .eq('id', user.id)
if (flagErr) {
  console.error(`✗ ${flagErr.message}`)
  process.exit(1)
}

const { data: after } = await supabase
  .from('profiles')
  .select('full_name, role, is_active, is_superadmin')
  .eq('id', user.id)
  .single()

console.log(`✓ ${after?.full_name ?? emails[0]} is the overseer.`)
console.log(`  role=${after?.role} active=${after?.is_active} overseer=${after?.is_superadmin}`)
if (after && after.is_active === false) {
  console.log('  ! This profile is inactive, and an inactive profile acts on nothing.')
  console.log('    Reactivate it before the flag has any effect.')
}
console.log('')
console.log('From now on, for this member only:')
console.log('  · every approval completes on their signature alone')
console.log('  · their own recorded payments settle without a second admin')
console.log('  · they cannot be demoted, deactivated or removed from inside the app')
console.log('  · every action is still written to audit_log')
console.log('')
console.log('To undo: npm run set-overseer -- --clear')
