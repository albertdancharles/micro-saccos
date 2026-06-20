# Micro-SACCOS — Umoja Group

A mobile-first PWA for a small savings & loan co-operative (SACCOS). Members pool
savings, pay a fixed monthly fee, request short-term loans (3-month bullet schedule,
5% flat monthly interest), and submit M-Pesa/Tigo/Airtel payment screenshots that the
admin verifies. Overdue fees and installments accrue a recurring 5% monthly penalty.

The admin is also a contributing member; their role only grants approval permissions.

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
