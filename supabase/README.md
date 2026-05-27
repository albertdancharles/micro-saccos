# Supabase

Database schema, RLS, storage, and RPCs for Micro-SACCOS. The authoritative spec is
`../../Umoja Group/micro-saccos-build-plan.md`.

The project uses the **hosted path** (no Docker). The local CLI path is kept below as an
alternative for when Docker/WSL2 are available.

---

## Hosted path (chosen — no Docker)

1. Create a project at <https://supabase.com>.
2. **Dashboard → SQL Editor → New query**, paste the entire **`setup.sql`** (it concatenates
   migrations 001–005 in order), and click **Run**. Safe on a fresh project.
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

`setup.sql` is these five files concatenated for the hosted one-shot paste. Keep it in sync if
you change a migration (regenerate by concatenating in order).

> Files use `001..005` names (per the build plan). If the CLI requires timestamped versions
> for `supabase db push`, rename to `<timestamp>_name.sql`; `supabase db reset` and the hosted
> paste apply them in order regardless.
