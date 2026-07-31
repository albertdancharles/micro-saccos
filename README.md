# Micro-SACCOS — Umoja Group

A mobile-first PWA for a small savings & loan co-operative (SACCOS). Members pool
savings, pay a monthly fee, request short-term loans (bullet schedule, flat monthly
interest), and submit M-Pesa/Tigo/Airtel payment screenshots that the admin verifies.
Overdue fees and installments accrue a recurring monthly penalty. The group runs in
cycles and shares out what it earned at the end of each one.

The admin is also a contributing member; their role only grants approval permissions.

**The group sets its own rules.** The monthly fee, loan interest, penalty rate, loan
caps and term all live in `group_settings` and change by 2-of-N admin vote — no code
change needed. A new rate only ever applies to *new* fees and loans: every obligation
snapshots the rate it was raised under, so a vote can never retroactively restate a
penalty someone has already been charged.

| Area | What it does |
|---|---|
| **Partial payments** | Pay what you have. Money is applied penalty → interest → principal, and the row is marked *part paid* until it's clear. Penalties then accrue on the balance still owed, not the original total. |
| **Loans that go bad** | Reschedule, write off, or settle against the borrower's own savings — each 2-of-N. `v_loan_risk` flags non-performance from the record rather than a flag someone has to remember to set. |
| **Cycles & share-out** | Close a cycle and split what the group earned. Shares are **time-weighted** (member-months), so a late joiner doesn't take an equal cut, and largest-remainder rounding means the shares sum exactly to the pot. Earnings-only or full share-out. |
| **Withdrawals & exit** | Members withdraw mid-cycle, capped by pool liquidity and by the savings held as security behind any active loan. Exit settles a member and deactivates them — *keeping* their history, unlike deletion. |
| **Reminders** | Notifications fan out to SMS (Africa's Talking) and Web Push, deduped per week so an overdue member is nudged, not spammed. A daily pg_cron sweep raises what's due. |
| **Guarantors** | Members co-sign each other's loans. An accepted pledge locks that much of the guarantor's savings; if the loan is written off the group can call the pledges pro-rata, capped at what each promised. |
| **Group accounts** | Income statement, balance sheet and a per-member ledger — the pack a co-operative reads at its AGM, exportable as CSV. |
| **Meetings** | Register, minutes, and attendance fines that are *deducted* from savings rather than invoiced. Plus a social fund (*bima ya jamii*) kept deliberately outside the loan pool. |

**The books are checked, not assumed.** `v_pool_reconciliation` derives the group's worth a
second way — member capital + retained earnings — and compares it to pool + outstanding loans.
The admin dashboard is silent while they agree and shouts if they ever don't.

## Testing

```bash
npm test          # pure financial helpers (Vitest)
npm run test:db:up && npm run test:db    # the money logic in SQL, against real Postgres
npm run lint && npm run build
```

The SQL suites apply every migration unmodified to a throwaway Postgres and assert the
arithmetic where it actually runs — see [supabase/README.md](supabase/README.md). CI runs all
of it on every push.

> **Security note — single-admin bootstrap.** Monetary actions (loan/payment approvals,
> savings/pool/role/deletion edits) require two of N admins. While only **one** admin
> exists, `required_approvals()` falls back to a single signature so the system stays
> usable. That first admin therefore holds elevated, un-countersigned power until a
> second admin is promoted — promote a second admin early, and note that every such
> action is still recorded in the `audit_log` regardless of admin count.

## Stack

- **React 19 + Vite** · **Tailwind CSS v4** · **React Router v7**
- **Supabase** — Postgres (RLS + status/penalty views), Auth (email/password), Storage
  (private `payment-proofs` bucket)
- **Vitest** for the pure financial helpers
- Currency: TZS via `Intl.NumberFormat('sw-TZ')`, whole shillings
- All date/overdue logic in East Africa Time (`Africa/Dar_es_Salaam`) via `today_eat()`

## Local development

```bash
npm install
cp .env.example .env.local   # then fill in the values below
npm run dev
```

### Environment (`.env.local`)

```env
VITE_SUPABASE_URL=https://<your-ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<anon public key>
```

The **service-role key is never put here** — it's only used by the seed script and
Edge Function, passed via shell env at run time.

## Supabase setup (hosted, no Docker)

1. Create a project at <https://supabase.com>.
2. **SQL Editor → New query**, paste all of [`supabase/setup.sql`](supabase/setup.sql)
   (migrations 001–005 concatenated), and Run. Safe on a fresh project.
3. Copy the project URL + anon key into `.env.local` (above).
4. **Seed the members** with the service-role key (edit the roster in
   [`scripts/seed.mjs`](scripts/seed.mjs) first):

   ```powershell
   $env:SUPABASE_URL="https://<your-ref>.supabase.co"
   $env:SUPABASE_SERVICE_ROLE_KEY="<service_role secret>"
   npm run seed
   ```

   Temp passwords are generated and printed once — distribute them; members reset on
   first login. Re-run any time to add new members (existing accounts are skipped).

See [`supabase/README.md`](supabase/README.md) for migration details and the local-CLI
alternative.

## Self-service registration & member approval (v3)

Members register themselves at **`/signup`** (email + password, or **Continue with
Google**) and supply their details — full name, primary & secondary phone, residence,
National ID (NIDA), and next of kin. New sign-ups are created **pending**
(`is_active = false`): they see an *Awaiting approval* screen and **cannot enter the
savings pool until an admin approves them** from the **Pending registrations** panel on
the admin dashboard. Google sign-ups (who arrive with only a name + email) are routed to
**`/complete-profile`** to fill the rest before approval.

Members can only ever edit their *own* details (via the `update_own_profile` RPC); a
member can never change their own `role` or `is_active`.

### Enable Google sign-in (one-time, dashboard)

1. **Auth → Providers → Google**: enable it and paste a Google OAuth **client ID** and
   **secret** (create them in the Google Cloud console; no per-use cost).
2. **Auth → URL Configuration**: set the **Site URL** to your deployed origin and add
   `…/` and `…/complete-profile` (plus `…/update-password`) to **Redirect URLs**.
3. **Auth → Providers → Email**: keep **Confirm email** ON so email/password sign-ups
   verify their address (membership still also needs admin approval).

### Cutover runbook — fresh start (DESTRUCTIVE)

> Deleting users **cascades** to all savings, loans, fees, installments, submissions,
> and history. There is no undo. **Back up first.** Order matters because deleting users
> removes the only admin.

1. **Back up** the database (Dashboard → Database → Backups, or `pg_dump`).
2. Apply migration **018** (`supabase/migrations/018_self_registration.sql`), or re-paste
   the updated [`supabase/setup.sql`](supabase/setup.sql) on a fresh project.
3. Redeploy the `admin-create-member` Edge Function and set the `ALLOWED_ORIGINS` secret.
4. **Delete all users** in the SQL editor (cascades to `profiles` and all financial data):

   ```sql
   -- Sanity check first:
   select count(*) as users_before from auth.users;
   delete from auth.users;
   select count(*) as users_after from auth.users;  -- expect 0
   ```

5. Deploy the new frontend, open **`/signup`**, and register
   `albertdancharles@gmail.com` with a password (and the profile fields).
6. **Promote + activate** that account (one statement):

   ```sql
   update profiles set role = 'admin', is_active = true
    where email = 'albertdancharles@gmail.com';
   ```

7. Sign in as that admin. Every later self-registration now appears under **Pending
   registrations** for you to approve or reject.

## Monthly fees

Fees are generated for all active members on the 1st of each month. `ensure_current_fees()`
runs on every dashboard load, so the current month self-heals even if a scheduler is
skipped — no cron is strictly required. To also automate it, enable **pg_cron** and run:

```sql
select cron.schedule('micro-saccos-monthly-fees', '1 0 1 * *',
  $$ select ensure_current_fees(); $$);
```

## Scripts

| Command | Purpose |
|---|---|
| `npm run dev` | Vite dev server |
| `npm run build` | Production build to `dist/` |
| `npm run preview` | Preview the production build |
| `npm run lint` | ESLint |
| `npm test` | Vitest (run once) |
| `npm run seed` | One-time member seeding (needs shell env, see above) |

## Deploy (Vercel)

Import the repo, set the two `VITE_SUPABASE_*` env vars in the project settings, and
deploy (build `npm run build`, output `dist`). Add your deployed origin to Supabase
**Auth → URL Configuration** redirect URLs so the password-reset link resolves.

## Structure

```
src/
  lib/        data access (auth, savings, loans, fees, payments, storage, admin) + format/loanMath helpers
  hooks/      useAuth (context), useProfile, useMemberSummary, useAdminData
  routes/     ProtectedRoute, RoleHome
  components/ ui/ (Badge, StatCard, Modal, UploadZone), member/, admin/
  pages/      Login, UpdatePassword, MemberDashboard, AdminDashboard
supabase/     migrations/, functions/, setup.sql
scripts/      seed.mjs
```

The authoritative spec is the build plan (kept outside this repo).
