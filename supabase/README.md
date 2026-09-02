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

5. **Monthly fees — schedule them.** `setup.sql` includes migration `017`, which enables
   pg_cron and registers the job, so on a fresh project this is already done. Verify rather
   than re-running:

   ```sql
   select jobid, jobname, schedule, command, active from cron.job;
   ```

   You want a job named **`generate-monthly-fees`** on `0 3 1 * *` (03:00 UTC = 06:00 EAT on
   the 1st). If the pg_cron extension was unavailable when you pasted `setup.sql`, you will
   know: `create extension pg_cron` raises and the SQL editor aborts the whole batch at that
   point, so everything from `017` onward is missing. Enable **pg_cron** (Dashboard → Database
   → Extensions) and paste from `017` on.

   > **Do not schedule this by hand under a different name.** An earlier version of this file
   > told you to create `micro-saccos-monthly-fees` on `1 0 1 * *`, which is the same call
   > under a different label. Any database set up from those instructions now has TWO jobs
   > doing the identical thing. It is harmless — `ensure_current_fees()` is an idempotent
   > upsert (`ON CONFLICT DO NOTHING`) and its audit row is guarded by `IF v_inserted > 0`, so
   > the second run of the day inserts nothing and logs nothing — but it is a trap: the next
   > person to unschedule one job will believe fee generation is off. Drop the ad-hoc one and
   > keep the one migration `017` owns:
   >
   > ```sql
   > select cron.unschedule('micro-saccos-monthly-fees');
   > ```

   > **This is the only generator.** `ensure_current_fees()` still runs when an ADMIN opens
   > the dashboard, as a safety net, but no longer when a member opens theirs — that was a
   > member-triggered write, which the admin mandate does not allow. Without the cron job, fee
   > generation waits for an admin to log in.
   >
   > The `generate-monthly-fees` **Edge Function** was deleted (it is only the cron job name
   > now). It authenticated nobody — service-role key on any unauthenticated invocation — and
   > hard-coded `amount: 10000`, ignoring `group_settings`, so a fee-amount vote would never
   > have reached it.

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
`SUPABASE_URL=http://127.0.0.1:54321` and the local service_role key). Fee scheduling is the
same pg_cron job as on the hosted path (`017`) — there is no Edge Function to schedule.

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
| `031`–`033` | loan multiplier, notification dispatch (Beem), Swahili message templates |
| `034_admin_mandate_lockdown.sql` | **members file nothing**; REVOKEs on the ten unguarded `SECURITY DEFINER` functions; `is_admin()` requires `is_active`; role/is_active out of reach of the browser; group reads scoped to active members |
| `035_drop_guarantors.sql` | guarantees removed entirely (**destructive** — drops `loan_guarantors`); `approve_loan` loses the guarantor check and the self-approval block |
| `036_admin_recording.sql` | `settle_submission()` split out of `approve_submission`; `record_fee_payments` (batch), `record_payment`, `file_loan`, `admin_request_withdrawal` |
| `037_payment_void.sql` | 2-of-N corrections: reverses the exact amounts the waterfall allocated, refuses once the schedule has moved on |

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

## The admin mandate (034–037)

Members are **read-only**. They see their own dashboard, the member directory, the group pool,
the income statement and the balance sheet — and they can change their own password, phone,
language and notification preferences. They cannot file a payment, request a loan, open a
withdrawal, or register an account.

Every transaction is keyed by an admin, and how many signatures it needs depends on what it is:

| Recording | Signatures |
|---|---|
| Another member's monthly fee (incl. the batch sheet) | 1 admin |
| Savings deposit, loan repayment | 2 admins |
| **An admin's own money, any type** | **2 admins, always** |
| Loan (file → approve + disburse) | 2 admins |
| Withdrawal (open → approve → pay out) | 2 admins |
| Void a posted entry | 2 admins |

`required_approvals()` is `least(2, active admins)`, so in a **one-admin group** everything
degrades to a single signature — except an admin's own money, which is hard-coded to need two.
That means **a lone admin cannot record their own fees, savings or repayments at all**;
`record_payment` says so explicitly rather than creating a row that can never settle. Promote a
second admin and it works.

### Two things that are not code

1. **Turn off email signups in the Supabase Auth dashboard.** Deleting `/signup` removed the
   page, not the endpoint. Until this is done, anyone can still create an account — they land
   inactive (the `handle_new_user` trigger defaults `is_active = false`) and can read nothing,
   but the account exists.
2. **Apply `017_schedule_monthly_fees.sql`.** `ensure_current_fees()` no longer runs when a
   member opens their dashboard — that was a member-triggered write — so it now fires only from
   the admin dashboard. Without the pg_cron job, fee generation waits for an admin to log in.

### Why 034 exists at all

The schema shipped with exactly **two** `REVOKE` statements, so every other function kept
Postgres' default `EXECUTE TO PUBLIC` — and ten `SECURITY DEFINER` functions had no
authorization check in their body. `execute_role_change` checked only `status = 'pending'`
before running `UPDATE profiles SET role`. Three of the ten had their request ids handed to
members by `USING (auth.uid() IS NOT NULL)` SELECT policies, which closes the loop: read a
pending id, apply it. **A member could promote themselves to admin; a borrower could write off
their own loan.**

`REVOKE ... FROM PUBLIC` alone does **not** fix this on Supabase. Supabase runs
`ALTER DEFAULT PRIVILEGES ... GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated,
service_role`, so every function is granted to `authenticated` explicitly on top of the implicit
PUBLIC grant. Dropping PUBLIC leaves the explicit grant standing. Always write
`REVOKE ALL ON FUNCTION f(...) FROM PUBLIC, anon, authenticated;`.

`supabase/tests/10_admin_mandate.test.sql` asserts every one of those escalations now raises.

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

### Reminders that reach a phone (026 + 032)

The SQL decides *what* to send; the `dispatch-notifications` Edge Function knows *how*. SMS
goes through **Beem Africa**.

> **Both halves are required.** 026 alone gives you a reminder sweep that fills a queue nobody
> drains — which is exactly what this project ran for weeks: an audit row every morning saying
> "10 reminders", and not one message delivered. 032 is what connects the queue to a phone, and
> `v_notification_health` is what tells you when it stops.

**1. Deploy the function.** `--no-verify-jwt` is deliberate: the anon key is public, so a JWT
check keeps nobody out. `DISPATCH_SECRET` is the real gate, and the function refuses to run at
all if it is unset.

```bash
npx supabase functions deploy dispatch-notifications --no-verify-jwt --project-ref <your-ref>
```

**2. Set its secrets** (Dashboard → Edge Functions → Secrets — never in `.env.local`):

| Secret | For |
|---|---|
| `BEEM_API_KEY`, `BEEM_SECRET_KEY` | Beem Africa SMS — from the Beem dashboard |
| `BEEM_SENDER_ID` | approved sender ID; defaults to `INFO`, which only reaches some networks |
| `DISPATCH_SECRET` | **required** — shared secret the caller sends as `x-dispatch-secret` |
| `TWILIO_SID`, `TWILIO_TOKEN`, `TWILIO_WHATSAPP_FROM` | WhatsApp (optional) |
| `DISPATCH_MAX_AGE_HOURS` | optional, default 48 — older queued rows expire unsent |

**3. Check the wiring before spending anything.** `check` reports which providers are
configured and how deep the queue is; `dry_run` shows the exact messages that would go out.
Neither sends anything.

```bash
curl -s -X POST 'https://<your-ref>.supabase.co/functions/v1/dispatch-notifications' \
  -H 'x-dispatch-secret: <DISPATCH_SECRET>' -H 'content-type: application/json' \
  -d '{"dry_run": true}'
```

**4. Schedule the drain** (every 15 minutes). Migration 026 schedules the daily sweep itself,
but draining needs the network, so it goes out through pg_net. The URL and secret are
arguments rather than hard-coded, so nothing sensitive lands in git:

```sql
select schedule_notification_drain(
  'https://<your-ref>.supabase.co/functions/v1/dispatch-notifications',
  '<the DISPATCH_SECRET you set above>'
);
```

> **pg_net must be enabled first** — Dashboard → Database → Extensions → `pg_net`. 039 installs
> it where the platform allows, but on a project where it is off the scheduled command
> (`select net.http_post(...)`) fails with `schema "net" does not exist` on every run, inside
> pg_cron where nothing surfaces it, while the queue keeps filling. Since 039
> `schedule_notification_drain` refuses outright rather than creating that job, so if this
> raises, enable the extension and run it again. Confirm both are present with:
>
> ```sql
> select extname from pg_extension where extname in ('pg_cron', 'pg_net');
> ```

**Watch it.** `select * from v_notification_health;` — `stuck` is the number that matters
(queued for over two hours means the drain is not running). The admin dashboard raises a
banner on the same signal, and stays silent otherwise.

Beem answers `200 OK` even when it has not accepted a message; the real outcome is the `code`
field. The dispatcher treats 101/104 (bad number, bad request) as permanent and stops
retrying, and 102 (no credit) as a group-wide block — it stops the batch and leaves the rows
queued **without** burning a retry, so topping up resumes exactly where it left off.

For Web Push, generate a VAPID pair (`npx web-push generate-vapid-keys`), put the public half
in `VITE_VAPID_PUBLIC_KEY` and the private half in the function's secrets. Push dispatch is
**not implemented** — those rows are marked `skipped` with a reason rather than retried. SMS is
unaffected.

### Messages are in Swahili (033)

Every notification is composed in English at 29 sites across 11 migrations, most of them inside
money-path triggers. Rather than edit those, a **`BEFORE INSERT` trigger on `notifications`**
rewrites each row into the recipient's `profiles.preferred_language` (default `sw`). It runs
before 026's `AFTER INSERT` fan-out, so the outbox inherits the translation — the in-app bell
and the SMS both change from one place.

- Phrases live in **`notification_templates` (kind, lang, title, body)**. To reword a message,
  update a row — no migration, no deploy. `{amount}`, `{delta}` and `{member}` are filled from
  the notification's own `data` payload (`{member}` resolves an id to a name).
- **`body IS NULL` means "keep the original body"** — used where the body is free text an admin
  typed, such as a rejection reason. The label is translated; their words are not.
- **No template for a kind → English, unchanged.** Nothing breaks when a new kind is added; it
  stays English until someone adds a row. `role_changed` is deliberately left out: its title
  depends on promote-vs-revoke, which `kind` alone cannot tell apart.
- `send_due_reminders` is translated in place instead, because it calls `enqueue_delivery`
  directly and never writes a `notifications` row.
- Money renders through `fmt_tzs()` as **"TSh 10,000"** to match the app's `formatTZS`, and
  dates through `fmt_day()` as `31/08/2026`. Previously SMS carried raw numerics ("10000.00 TZS").
- The app's language toggle now also saves to `preferred_language`, so a member reading the app
  in English gets English texts. Existing `notifications` rows are not retranslated.

> Files use `001..005` names (per the build plan). If the CLI requires timestamped versions
> for `supabase db push`, rename to `<timestamp>_name.sql`; `supabase db reset` and the hosted
> paste apply them in order regardless.
