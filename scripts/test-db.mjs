// scripts/test-db.mjs — runs the SQL test suite against a throwaway Postgres.
//
//   npm run test:db
//
// Point TEST_DATABASE_URL at any empty Postgres 15+ database. Anything works: a
// `postgres:17` container in CI, a local install, or a throwaway hosted project.
// No Docker and no Supabase stack required — supabase/tests/bootstrap.sql shims the
// handful of auth/storage/cron objects the migrations touch (see its header).
//
// What it does, per run:
//   1. drops and recreates the `public` schema, so every run starts clean
//   2. applies bootstrap.sql
//   3. applies EVERY migration in order, byte-for-byte as it ships — so a migration
//      that cannot apply in sequence is itself a test failure
//   4. applies fixtures.sql (grants + impersonation + assertion helpers)
//   5. runs each *.test.sql inside BEGIN … ROLLBACK, so files cannot leak state
//      into each other and the database is reusable without a reset between files
//
// Exit code is non-zero if any file fails, which is what CI keys off.
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import pg from 'pg'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const MIGRATIONS = join(ROOT, 'supabase', 'migrations')
const TESTS = join(ROOT, 'supabase', 'tests')

// Infrastructure-only migrations that cannot apply to a plain Postgres and hold no
// business logic to test:
//   004 — storage bucket + object policies; needs the real storage extension
//   017 — `create extension pg_cron`, which needs the extension binary present
// Everything else, including all the money logic, is applied unmodified.
const SKIP = new Set(['004_storage_bucket.sql', '017_schedule_monthly_fees.sql'])

// Port 55432, not 5432 — this script DROPS SCHEMA public CASCADE on whatever it
// connects to, so the default must never be a port something else might be using.
// `npm run test:db:up` starts a container matching this exactly.
const CONN =
  process.env.TEST_DATABASE_URL ||
  'postgresql://postgres:postgres@127.0.0.1:55432/micro_saccos_test'

const red = (s) => `\x1b[31m${s}\x1b[0m`
const green = (s) => `\x1b[32m${s}\x1b[0m`
const dim = (s) => `\x1b[2m${s}\x1b[0m`

const sqlFiles = (dir, filter) => readdirSync(dir).filter(filter).sort()

async function main() {
  const client = new pg.Client({ connectionString: CONN })
  try {
    await client.connect()
  } catch (err) {
    console.error(red('Could not connect to the test database.'))
    console.error(dim(`  ${CONN.replace(/:[^:@/]*@/, ':***@')}`))
    console.error(dim('  Run `npm run test:db:up` first, or set TEST_DATABASE_URL.'))
    console.error(dim(`  ${err.message}`))
    process.exit(1)
  }

  // A clean slate every run: a leftover object from a previous run could mask a
  // migration that no longer creates what the tests assume.
  await client.query('DROP SCHEMA IF EXISTS public CASCADE')
  await client.query('DROP SCHEMA IF EXISTS auth CASCADE')
  await client.query('DROP SCHEMA IF EXISTS storage CASCADE')
  await client.query('DROP SCHEMA IF EXISTS cron CASCADE')
  await client.query('DROP SCHEMA IF EXISTS tests CASCADE')
  await client.query('CREATE SCHEMA public')

  await client.query(readFileSync(join(TESTS, 'bootstrap.sql'), 'utf8'))

  const migrations = sqlFiles(MIGRATIONS, (f) => f.endsWith('.sql'))
  let applied = 0
  for (const file of migrations) {
    if (SKIP.has(file)) {
      console.log(dim(`  skip  ${file}`))
      continue
    }
    try {
      await client.query(readFileSync(join(MIGRATIONS, file), 'utf8'))
      applied++
    } catch (err) {
      console.error(red(`\n  FAIL  ${file} could not be applied`))
      console.error(`        ${err.message}`)
      await client.end()
      process.exit(1)
    }
  }
  console.log(dim(`  applied ${applied} migrations`))

  await client.query(readFileSync(join(TESTS, 'fixtures.sql'), 'utf8'))

  const tests = sqlFiles(TESTS, (f) => f.endsWith('.test.sql'))
  if (tests.length === 0) {
    console.error(red('No .test.sql files found in supabase/tests'))
    await client.end()
    process.exit(1)
  }

  let passed = 0
  const failures = []
  for (const file of tests) {
    // Each file is its own transaction and is always rolled back, so the tests are
    // order-independent and leave nothing behind.
    await client.query('BEGIN')
    try {
      await client.query(readFileSync(join(TESTS, file), 'utf8'))
      await client.query('ROLLBACK')
      console.log(`  ${green('PASS')}  ${file}`)
      passed++
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {})
      // RESET ROLE: as_user() may have left the session as `authenticated`, which
      // would break the next file's fixture creation.
      await client.query('RESET ROLE').catch(() => {})
      console.log(`  ${red('FAIL')}  ${file}`)
      console.log(`        ${err.message}`)
      failures.push(file)
    }
  }

  await client.end()

  console.log('')
  if (failures.length) {
    console.log(red(`  ${failures.length} failed`) + dim(`, ${passed} passed`))
    process.exit(1)
  }
  console.log(green(`  ${passed} passed`))
}

main().catch((err) => {
  console.error(red(err.stack || err.message))
  process.exit(1)
})
