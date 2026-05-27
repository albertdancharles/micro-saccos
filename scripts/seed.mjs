// One-time seed: create the member accounts and promote one to admin.
// Provide creds via SHELL ENV at run time — never hard-code or commit secrets:
//   $env:SUPABASE_URL="https://<your-ref>.supabase.co"
//   $env:SUPABASE_SERVICE_ROLE_KEY="<service_role secret>"
//   node scripts/seed.mjs        (or: npm run seed)
//
// The handle_new_user trigger populates profiles from user_metadata, so we pass
// full_name + phone_number there. Edit the `members` list below before running.
import { createClient } from '@supabase/supabase-js'
import { randomInt } from 'node:crypto'

const url = process.env.SUPABASE_URL
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY

if (!url || !serviceKey) {
  console.error('Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY first (see header).')
  process.exit(1)
}

const supabase = createClient(url, serviceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
})

// The current Umoja Group roster. Only Albert has a real email; the rest use
// name-based synthetic logins (@umojagroup.app) since the app authenticates by
// email + password (Decision #9). More members are added later by re-running this
// (already-created accounts simply error out and are skipped — safe to re-run).
// - email is the LOGIN identifier; phone_number is stored on the profile (+255 E.164).
// - Leave `password` blank → a strong temp password is generated and PRINTED at the
//   end so the admin can distribute it. Members change it on first login.
// - Exactly ONE entry must have admin: true.
const members = [
  { full_name: 'Albert Charles',    email: 'albertdancharles@gmail.com',     phone_number: '+255655500410', password: '', admin: true },
  { full_name: 'Kelvin Sinde',      email: 'kelvin.sinde@umojagroup.app',     phone_number: '+255753463567', password: '' },
  { full_name: 'Nuru Mwakisyala',   email: 'nuru.mwakisyala@umojagroup.app',  phone_number: '+255716731151', password: '' },
  { full_name: 'Amani Ngoko',       email: 'amani.ngoko@umojagroup.app',      phone_number: '+255717195783', password: '' },
  { full_name: 'Raheli Mosha',      email: 'raheli.mosha@umojagroup.app',     phone_number: '+255757595443', password: '' },
  { full_name: 'Veroda Makunja',    email: 'veroda.makunja@umojagroup.app',   phone_number: '+255679044511', password: '' },
  { full_name: 'Peter Okama',       email: 'peter.okama@umojagroup.app',      phone_number: '+255621328108', password: '' },
  { full_name: 'Yuda Ntandu',       email: 'yuda.ntandu@umojagroup.app',      phone_number: '+255621115735', password: '' },
  { full_name: 'Massoud Massoud',   email: 'massoud.massoud@umojagroup.app',  phone_number: '+255655036403', password: '' },
  { full_name: 'Deus Owano',        email: 'deus.owano@umojagroup.app',       phone_number: '+255737646188', password: '' },
  { full_name: 'Pius Mushi',        email: 'pius.mushi@umojagroup.app',       phone_number: '+255764174646', password: '' },
  { full_name: 'Silivana Kambanga', email: 'silivana.kambanga@umojagroup.app',phone_number: '+255756300222', password: '' },
  { full_name: 'Jackson Onyango',   email: 'jackson.onyango@umojagroup.app',  phone_number: '+255712154837', password: '' },
]

// Temp-password generator. Avoids ambiguous chars (0/O/1/l/I) so it's easy to dictate.
const PW_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
function genPassword(len = 10) {
  let s = ''
  for (let i = 0; i < len; i++) s += PW_ALPHABET[randomInt(PW_ALPHABET.length)]
  return s
}

// --- Validate the template before touching the database ---
// password is optional (auto-generated when blank); name/email/phone are required.
const filled = members.filter((m) => m.full_name || m.email || m.phone_number)
const incomplete = filled.filter((m) => !(m.full_name && m.email && m.phone_number))
if (incomplete.length) {
  console.error(`${incomplete.length} row(s) are partially filled. Complete full_name, email, and phone_number, or leave the row entirely blank.`)
  process.exit(1)
}
if (!filled.length) {
  console.error('No members filled in. Edit the `members` list in scripts/seed.mjs first.')
  process.exit(1)
}
const admins = filled.filter((m) => m.admin)
if (admins.length !== 1) {
  console.error(`Exactly one member must have admin: true (found ${admins.length}).`)
  process.exit(1)
}

const created = []  // { email, password } for the end-of-run summary

for (const m of filled) {
  const password = m.password || genPassword()

  const { data, error } = await supabase.auth.admin.createUser({
    email: m.email,
    password,
    email_confirm: true,
    user_metadata: { full_name: m.full_name, phone_number: m.phone_number },
  })

  if (error) {
    console.error(`✗ ${m.email}: ${error.message}`)
    continue
  }
  console.log(`✓ created ${m.email}`)
  created.push({ email: m.email, password })

  if (m.admin) {
    const { error: upErr } = await supabase
      .from('profiles')
      .update({ role: 'admin' })
      .eq('id', data.user.id)
    console.log(upErr ? `✗ promote admin: ${upErr.message}` : `✓ promoted ${m.email} to admin`)
  }
}

if (created.length) {
  console.log('\n=== Temp passwords (distribute securely; members change on first login) ===')
  for (const c of created) console.log(`${c.email}\t${c.password}`)
  console.log('==========================================================================')
}
console.log(`\nSeed complete. Created ${created.length} of ${filled.length}.`)
