# Supabase

Database schema, RLS, storage, and RPCs for Micro-SACCOS. The authoritative spec is
`../../Umoja Group/micro-saccos-build-plan.md`.

The project uses the **hosted path** (no Docker). The local CLI path is kept below as an
alternative for when Docker/WSL2 are available.

---

## Hosted path (chosen — no Docker)

1. Create a project at <https://supabase.com>.
2. **Dashboard → SQL Editor → New query**, paste the entire **`setup.sql`** (generated: every
   migration in order — run `npm run build:setup` first if you have changed one), and click
   **Run**. Safe on a fresh project.
3. **Project Settings → API**, then wire the app's `.env.local` (see `../.env.example`):

   ```env
   VITE_SUPABASE_URL=https://<your-ref>.supabase.co
   VITE_SUPABASE_ANON_KEY=<anon public key>
   ```

4. **Seed the 15 accounts** with the *service_role* key (also under Settings → API). Edit the
   member list in `../scripts/seed.mjs` first, then from the repo root:

   ```powershell
   $env:SUPABASE_URL="https://<your-ref>.supabase.co"
   $env:SUPABASE_SERVICE_ROLE_KEY="<service_role secret>"
   npm run seed
   ```

5. **Monthly fees.** `ensure_current_fees()` runs on every dashboard load, so the current
   month's fees self-heal without any scheduler — this is enough. To also automate it,
   enable the **pg_cron** extension (Dashboard → Database → Extensions) and run once:

   ```sql
   select cron.schedule(
     'micro-saccos-monthly-fees',
     '1 0 1 * *',                      -- 00:01 UTC on the 1st (still the 1st in EAT)
     $$ select ensure_current_fees(); $$
   );
   ```

   > On the hosted-SQL path you do **not** deploy the Edge Function
   > (`functions/generate-monthly-fees/index.ts`) — the pg_cron call above replaces it.
   > The Edge Function is only needed if you later adopt the CLI/local path.

---

## Local path (alternative — needs Docker + WSL2)

Prerequisites: Docker Desktop running, plus the Supabase CLI (already a dev-dependency here,
invoked via `npx supabase`).

```powershell
npx supabase init       # generates config.toml; keeps these migrations/functions
npx supabase start      # boots the local Postgres + Auth + Storage stack (Docker)
npx supabase db reset   # applies migrations/001..005 from scratch
```

Then copy the printed local URL + keys into `.env.local` and seed (same `npm run seed`, with
`SUPABASE_URL=http://127.0.0.1:54321` and the local service_role key). Add the cron schedule
to `config.toml`:

```toml
[functions.generate-monthly-fees]
schedule = "1 0 1 * *"   # 00:01 on the 1st of every month
```

---

## Migration order

| File | Contents |
|---|---|
| `001_create_tables.sql` | `today_eat()` helper, profiles (+ signup trigger), monthly_fees, loans, loan_installments, payment_submissions |
| `002_create_views.sql` | overdue + penalty status/money views, `v_group_pool` |
| `003_rls_policies.sql` | `is_admin()`, RLS policies, view grants |
| `004_storage_bucket.sql` | private `payment-proofs` bucket (image-only ≤5 MB) + storage policies |
| `005_rpc_functions.sql` | `approve_loan`, `approve_submission`, `ensure_current_fees`, `reject_submission`, `reject_loan` |
| `006`–`019` | member self-service, audit log, 2-of-N approvals, notifications, member deletion, flexible repayment, group assets, savings/pool/role edits, monthly fee scheduling, self-registration, transparency directory |
| `020_group_settings.sql` | `group_settings` + `setting()`; rates snapshotted onto fees/loans; 2-of-N rule changes |
| `021_partial_payments.sql` | allocation waterfall, `partial` status, `earnings_ledger`, `v_group_pool` cash correction |
| `022_loan_distress.sql` | restructure / write-off / recover-from-savings, `v_loan_risk` |
| `023_cycles.sql` | `cycles`, time-weighted `member_cycle_basis()`, `cycle_earnings()` |
| `024_share_out.sql` | `distributions`, `preview_cycle_close()`, 2-of-N `close_cycle`, payouts |
| `025_withdrawals_and_exit.sql` | withdrawals with the loan-collateral guard, member exit (settle + deactivate, history kept) |
| `026_notification_delivery.sql` | delivery outbox, E.164 normalisation, push subscriptions, daily reminder sweep |
| `027_reconciliation.sql` | `v_pool_reconciliation` (assets = claims) + `security_invoker` on the member-scoped views |
| `028_loan_guarantors.sql` | co-signers, the pledge lock in `member_withdrawable()`, auto-release, pro-rata calling |
| `029_reports.sql` | income statement, balance sheet, per-member ledger, AGM member report |
| `030_meetings_and_social_fund.sql` | meeting register, attendance fines (deducted, not invoiced), social fund |

`setup.sql` is **generated** — every migration above, concatenated in order, for the hosted
one-shot paste. Never edit it by hand:

```bash
npm run build:setup            # regenerate after adding or changing a migration
npm run build:setup -- --check # what CI runs; fails if it is out of date
```

It used to be maintained manually and drifted twice, most recently sitting eight migrations
behind — so anyone following the documented setup path built a database with no group settings,
no partial payments, no cycles and no withdrawals, and nothing said so.

---

## Testing the SQL

The money logic lives in plpgsql, so it needs testing where it runs, not only through the JS
mirrors in `src/lib`. `npm run test:db` applies **every migration unmodified** to a throwaway
Postgres and runs the assertions in `tests/*.test.sql`.

```bash
npm run test:db:up     # throwaway postgres:17 on port 55432 (Docker)
npm run test:db        # apply migrations + run the suites
npm run test:db:down   # tear it down
```

No Supabase stack is needed: [`tests/bootstrap.sql`](tests/bootstrap.sql) shims the four things
the migrations touch outside `public` — `auth.uid()`, `auth.users`, `storage.*` and `cron.*`.
Any empty Postgres 15+ works; set `TEST_DATABASE_URL` to point elsewhere (CI uses a service
container). `004` and `017` are skipped by the runner — both are infrastructure that needs the
real extensions and neither holds business logic.

| Suite | Protects |
|---|---|
| `01_settings` | a rate change must never restate a penalty already charged |
| `02_allocation` | the payment waterfall: penalty → interest → principal, part payments, early repayment |
| `03_pool` | `v_group_pool` through deposits, fees, disbursement, early repayment, write-off, recovery, withdrawal |
| `04_shareout` | time-weighted shares, largest-remainder rounding, immutable snapshots |
| `05_guards` | the real 2-of-N path, the withdrawal collateral cap, and per-member view scoping |
| `06_guarantors` | the pledge lock, pro-rata calling, automatic release on repayment |
| `07_reports` | the balance sheet balances and agrees with `v_pool_reconciliation` |
| `08_meetings` | fines reach savings *and* earnings; the social fund stays out of the loan pool |

> `05_guards` is the only suite with **three** admins. Everywhere else a single admin means
> `required_approvals()` falls back to 1 and the two-signature logic never actually runs.

Most suites call `tests.assert_balanced(...)` after every money movement, so any change that
breaks the assets-equal-claims identity fails immediately rather than surfacing later as a
number nobody can explain. That check has already caught one real bug (attendance fines were
being counted as both a cash outflow and group income).

### Applying 020–026

They build on each other and must go in order (021 needs 020's `penalty_rate` columns, 023
needs 021's `earnings_ledger`, and so on). Paste each into the SQL editor and Run.

**Apply them to a Supabase branch or a throwaway project first.** 021 rewrites `v_group_pool`
to count cash actually received rather than contracted amounts — verify `select * from
v_group_pool` is unchanged for your existing data before running it against live.

### Reminders that reach a phone (026)

The SQL decides *what* to send; the `dispatch-notifications` Edge Function knows *how*. Deploy
it and set its secrets (Dashboard → Edge Functions → Secrets — never in `.env.local`):

| Secret | For |
|---|---|
| `AT_API_KEY`, `AT_USERNAME`, `AT_SENDER_ID` | Africa's Talking SMS |
| `TWILIO_SID`, `TWILIO_TOKEN`, `TWILIO_WHATSAPP_FROM` | WhatsApp (optional) |
| `DISPATCH_SECRET` | shared secret the caller sends as `x-dispatch-secret` |

Migration 026 schedules the daily reminder sweep itself via pg_cron. Draining the outbox needs
network access, so schedule the function separately (pg_cron + pg_net, every 15 minutes):

```sql
select cron.schedule(
  'drain-notification-outbox',
  '*/15 * * * *',
  $$ select net.http_post(
       url     := 'https://<your-ref>.supabase.co/functions/v1/dispatch-notifications',
       headers := '{"x-dispatch-secret": "<DISPATCH_SECRET>"}'::jsonb
     ); $$
);
```

For Web Push, generate a VAPID pair (`npx web-push generate-vapid-keys`), put the public half
in `VITE_VAPID_PUBLIC_KEY` and the private half in the function's secrets. Without it the
"notify me on this device" toggle stays disabled and SMS still works.

> Files use `001..005` names (per the build plan). If the CLI requires timestamped versions
> for `supabase db push`, rename to `<timestamp>_name.sql`; `supabase db reset` and the hosted
> paste apply them in order regardless.
