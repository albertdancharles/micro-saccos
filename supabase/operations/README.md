# Operations

One-off SQL run by hand against a **specific** database at a **specific** moment.

**These are not migrations, and they must never move into `supabase/migrations/`.**
`scripts/build-setup.mjs` folds every file in that directory into `setup.sql`, and
`scripts/test-db.mjs` applies every one of them to the test database. Either would be
wrong here: a fresh project has no fees to delete and should start with the group's real
penalty rate, not with whatever one group decided one afternoon.

Migrations describe the schema every database must have. These describe a decision one
group made about its own data. Keep them apart.

Each file is dated, states what it did, and is written to be safe to re-read later by
someone reconstructing why the numbers look the way they do. Run them from the Supabase
SQL editor.

| File | When | What |
|---|---|---|
| `2026-08-25_opening_balance_reset.sql` | once, 2026-08-25 | Cleared 17 unpaid fee rows (170,000 base, 6,500 penalty) and set `penalty_rate` to 0. The group starts collecting in September 2026. |
| `2026-09-01_clear_august_fees.sql` | once, on or after 2026-09-01 | Deletes the August fee row that `ensure_current_fees()` regenerates after the reset. |
