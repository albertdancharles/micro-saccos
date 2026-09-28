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
| **Withdrawals & exit** | An admin opens a withdrawal on a member's behalf, capped by pool liquidity and by the savings held as security behind any active loan. Exit settles a member and deactivates them — *keeping* their history, unlike deletion. A former member is therefore `is_active = false`, the same as an unapproved sign-up, so `has_member_history()` (`040`) keeps them out of the applicant queue: neither reinstating them nor deleting them as an "applicant" is possible. |
| **Reminders** | Notifications fan out to SMS (Beem Africa) and Web Push, deduped per week so an overdue member is nudged, not spammed. A daily pg_cron sweep raises what's due. |
| **Admin mandate** | Members are read-only: every transaction is keyed by an admin, enforced in the database rather than by hiding buttons. A monthly batch sheet posts the whole group's fees at once. |
| **Corrections** | Because the admin now keys the amount, the typo is theirs. A 2-of-N void reverses the *exact* figures the waterfall allocated — recomputing a penalty later would use today's date and give a different answer — and refuses once the schedule has moved on. |
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

> **Security note — the overseer (041).** One profile may hold `is_superadmin`. For
> that member, and only that member, the two-of-N rule does not apply at any admin
> count: requests execute on their own signature, their own recorded payments settle
> without a second admin, and the loan-free-admin mandate does not bind them. This is
> a deliberate concentration of authority, not a bootstrap fallback — it does not
> lapse when a second admin is promoted. What it does **not** remove:
>
> - **The audit log.** Every overseer action is still written to `audit_log`, which is
>   the only remaining check on the office. Read it at `/admin/audit`.
> - **The lending caps.** `pool_loan_fraction` and `contribution_multiplier` still
>   apply. They are `group_settings` rows rather than admin confirmations — though the
>   overseer can now change them alone, which the settings history records.
>
> The flag is settable **only** from the service role — `protect_overseer()` refuses
> any change to it that arrives with an `auth.uid()`, so no admin can grant it to
> themselves through the app, and no number of admins can strip it. While it is held,
> that profile also cannot be demoted, deactivated or deleted from inside the app.
> Both granting and revoking go through the key holder:
>
> ```
> npm run set-overseer -- albertdancharles@gmail.com   # grant
> npm run set-overseer -- --clear                      # stand down (the recovery path)
> ```
>
> If that account is lost, the service-role key is the only way back — clear the flag
> before demoting, settling out or removing the member.

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

## Accounts and access (the admin mandate)

Members are **read-only**. They see their own dashboard, the member directory, the group
pool, the income statement and the balance sheet, and they can change their own password,
phone, language and notification preferences. They cannot file a payment, request a loan,
open a withdrawal, or register an account. This is enforced in the database — migration
`034` dropped the member INSERT policies on `loans` and `payment_submissions`, so it holds
even against a direct PostgREST call, not just a hidden button.

**Admins create every account.** There is no `/signup`, no `/complete-profile` and no
`/pending`; self-registration and Google sign-in were removed along with the flow they
served. Use **+ Add member** on the admin dashboard, which calls the `admin-create-member`
Edge Function (service role, admin-gated) and returns the member's sign-in PIN to hand over
(plus a temp password for the backup email login).

### How members sign in (migration `042`)

Members sign in with **first name + phone number + PIN**. That is the default tab on the
login screen; email + password is the second tab and is what the admin uses.

Why a PIN and not just name + phone, which is what was asked for: everyone in the group knows
everyone's first name and phone number, and `full_name` is already published in-app by
`group_member_directory()`, so with no secret the group's own phone list is a working
credential for every account in it. Members can't file loans or payments — `034` took that
away — so the exposure isn't forged requests. It's reading another member's dashboard and
profile PII, taking over their login by changing their phone number, and signing in as an
**admin**, whose session approves loans and records payments, and whose signature alone is a
quorum if they're the overseer (`041`). Name and phone identify; the PIN authenticates.

- **4–6 digits.** All-same-digit and straight runs (`1234`, `9876`) are refused.
- **Hashed** with PBKDF2-SHA256 in the `member-pin-auth` Edge Function, never in SQL. A PIN
  is small enough to brute-force at any iteration count, so the control that actually
  protects the account is the attempt limit: **5 tries, then a 15-minute lockout**, counted
  against the phone number that was *typed* so an unknown number throttles identically and
  the endpoint cannot be used to ask who is in the group.
- **`member_pins` and `phone_login_attempts` are service-role only** — RLS on, no policies.
  `15_phone_pin_login.test.sql` asserts a member's JWT cannot reach either, or any of the
  lookup functions. (It caught a real hole on its first run: revoking `FROM public` is not
  enough, because Supabase's `ALTER DEFAULT PRIVILEGES` hands `anon` and `authenticated` an
  explicit grant at create time.)
- **Phone numbers are normalised.** `0712…`, `+255712…` and `255712…` are one number, and a
  unique index enforces that exactly one member holds it. Migration `042` refuses to apply if
  existing data already has a collision, and names the numbers to fix.
- **An admin-issued PIN is a stop, not a suggestion.** It is flagged `must_change`, and
  `ProtectedRoute` holds the member on `/set-pin` until they choose their own — while two
  people know the PIN, nothing filed in that member's name is evidence they filed it.
- **No self-service reset.** A synthetic `@umojagroup.app` address has no inbox, so there is
  nowhere to send a reset. The **Sign-in PINs** panel on the admin dashboard is the whole
  recovery path: it shows who has no PIN, who is locked out, and who is still on an
  admin-issued one, and issues a new PIN that is shown once.

**Rolling this out to existing members:** they have no PIN until one is issued, so phone login
will reject them (email + password keeps working throughout). After applying `042`, open
**Sign-in PINs** on the admin dashboard and reset each member, handing the PIN over the same
way a temp password was handed over.

### One-time dashboard settings

1. **Auth → Providers → Email**: **turn Enable Sign Up OFF.** Deleting the `/signup` page
   removed the UI, not the endpoint. Until this is off, anyone can still create an account.
   They land inactive — the `handle_new_user` trigger defaults `is_active = false` and `034`
   scoped every group-wide read policy to `is_active_member()`, so they can read nothing —
   but the account exists and you have to clean it up.
2. **Auth → URL Configuration**: **Site URL** = your deployed origin; **Redirect URLs** need
   only `…/` and `…/update-password`. (`…/complete-profile` is gone.)
3. Keep **Confirm email** ON — it still matters for password resets.
4. Redeploy `admin-create-member` and set its `ALLOWED_ORIGINS` secret. It is now the only
   way a member can come into existence, so it is worth confirming it works end to end.
   (`042` also made it return the new profile's `id`, which the Add member dialog needs to
   mint the PIN — an older deployed copy will create members with no PIN.)
5. Deploy `member-pin-auth` with **Verify JWT OFF**, and set its `ALLOWED_ORIGINS` secret.
   The switch has to be off because signing in happens before there is a JWT to verify; the
   function verifies the caller itself for the two actions that need it (`set_pin` checks the
   session, `reset_pin` additionally checks the caller is an admin). With Verify JWT left on,
   phone login fails for everyone with a 401.

### Who signs what

| Recording | Signatures |
|---|---|
| Another member's monthly fee (incl. the batch sheet) | 1 admin |
| Savings deposit, loan repayment | 2 admins |
| **An admin's own money, any type** | **2 admins, always** |
| Loan (file → approve + disburse) | 2 admins |
| Withdrawal (open → approve → pay out) | 2 admins |
| Void a posted entry | 2 admins |

`required_approvals()` is `least(2, active admins)`, so in a **one-admin group** everything
degrades to a single signature — except an admin's own money, which is hard-coded to need
two. That means **a lone admin cannot record their own fees, savings or repayments at all**;
`record_payment` says so rather than creating a row that can never settle. Promote a second
admin and it works.

Members can still edit their *own* details via the `update_own_profile` / `update_own_phone`
RPCs, and can never change their own `role` or `is_active` — `034` revoked `UPDATE` on
`profiles` from `authenticated` outright, so those columns are unreachable from the browser
and move only through the voted RPCs.

## Monthly fees

Fees are generated for all active members on the 1st of each month by a **pg_cron job**,
registered by migration `017` and named `generate-monthly-fees`:

```sql
select jobid, jobname, schedule, command, active from cron.job;
```

`ensure_current_fees()` also runs when an **admin** opens the dashboard, as a safety net. It
no longer runs when a member opens theirs — that was a member-triggered write, which the
admin mandate does not allow — so unlike previous versions, **the cron job is not optional**.
Without it, fee generation waits for an admin to log in.

Do not schedule it by hand under another name; see the note in
[`supabase/README.md`](supabase/README.md#L45) about the duplicate
`micro-saccos-monthly-fees` job that earlier instructions produced.

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
