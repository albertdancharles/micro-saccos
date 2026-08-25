// scripts/build-setup.mjs — regenerates supabase/setup.sql from the migrations.
//
//   npm run build:setup          rewrite setup.sql
//   npm run build:setup -- --check   exit non-zero if it is out of date (used by CI)
//
// Why this exists: setup.sql is the one-shot paste for standing up a fresh project,
// and it was maintained by hand. It drifted twice — most recently sitting eight
// migrations behind, so anyone following the documented setup path would have built
// a database with no group settings, no partial payments, no cycles and no
// withdrawals, and nothing would have told them. Generating it makes drift a failing
// build instead of a silently broken deployment.
import { readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const MIGRATIONS = join(ROOT, 'supabase', 'migrations')
const OUT = join(ROOT, 'supabase', 'setup.sql')

const files = readdirSync(MIGRATIONS)
  .filter((f) => f.endsWith('.sql'))
  .sort()

const header = `-- ===========================================================================
-- setup.sql — GENERATED FILE. DO NOT EDIT BY HAND.
--
-- Every migration in supabase/migrations, concatenated in order, for the hosted
-- one-shot paste: Supabase Dashboard -> SQL Editor -> New query -> Run.
--
-- Regenerate with:  npm run build:setup
-- CI fails if this file does not match the migrations it is built from.
--
-- Two migrations need a note when running this on a fresh project:
--   * 004 requires the storage schema (present on every Supabase project)
--   * 017 enables pg_cron. If the extension is not available the statement RAISES
--     and the SQL editor aborts the batch there, so everything after 017 is
--     missing too — enable pg_cron and paste from 017 on. Do not just skip it:
--     since the admin mandate, ensure_current_fees() runs only when an ADMIN
--     opens the dashboard (a member opening theirs used to trigger it, which was
--     a member-initiated write), so without the cron job fee generation waits on
--     an admin logging in.
--
-- ${files.length} migrations: ${files[0]} .. ${files[files.length - 1]}
-- ===========================================================================

`

const body = files
  .map((f) => {
    const sql = readFileSync(join(MIGRATIONS, f), 'utf8').trimEnd()
    return `-- ---------------------------------------------------------------------------\n-- ${f}\n-- ---------------------------------------------------------------------------\n\n${sql}\n`
  })
  .join('\n')

const generated = header + body

if (process.argv.includes('--check')) {
  let current = ''
  try {
    current = readFileSync(OUT, 'utf8')
  } catch {
    /* missing counts as out of date */
  }
  if (current !== generated) {
    console.error('setup.sql is out of date. Run `npm run build:setup` and commit the result.')
    process.exit(1)
  }
  console.log(`setup.sql is up to date (${files.length} migrations).`)
} else {
  writeFileSync(OUT, generated)
  console.log(`Wrote setup.sql from ${files.length} migrations.`)
}
