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

**Order.** The two 2026-09-29 savings files run in the order their rows give. The pool and
social fund files below them are independent of each other, and of the fee file as long as
it runs with `v_offset_opening := true` (which leaves the pool at 3,220,000). Run the fee
file with the offset off and the pool becomes 3,360,000 — the pool file will then refuse to
run rather than land on the wrong total, which is the point of its guard.

The loans file goes **last**. It needs the profit in the pool — 3,932,700 of lending against
a 3,220,000 pool overdraws it by 712,700 — and it checks, so running it early costs nothing
but a refusal.

Apply migration `045_loan_cap_on_group_assets.sql` before or after these, but do apply it. The
loans file computes its own report either way, but `approve_loan` does not: until 045 lands it
measures the 25% ceiling against the liquid pool, which this recording leaves at zero, so the
next loan filed in the app would be refused for a reason the group did not vote for.

| File | When | What |
|---|---|---|
| `2026-08-25_opening_balance_reset.sql` | once, 2026-08-25 | Cleared 17 unpaid fee rows (170,000 base, 6,500 penalty) and set `penalty_rate` to 0. The group starts collecting in September 2026. |
| `2026-09-01_clear_august_fees.sql` | **never run — superseded 2026-09-15** | Would have deleted the August fee rows that `ensure_current_fees()` regenerated after the reset. Dropped because the group collected August (6 of 7 paid on 2026-09-12). Its DELETE is commented out; **do not re-enable it** — it would erase paid history. |
| `2026-09-29_savings_opening_balance_230k.sql` | once, 2026-09-29 | Credited 230,000 TZS of savings to every active member as one approved `savings_adjustments` row each — the per-member opening balances the 2026-08-25 reset deferred. Raised the pool by the same total (14 members, 3,220,000). |
| `2026-09-29_september_fee_collected.sql` | **not yet run — run after the file above** | Records the September 2026 fee as collected at the 26 Sep meeting and takes the same amount back off each opening balance, so savings totals and the pool do not move (230,000 = 220,000 opening + 10,000 fee). Touches only the members whose September row is still unpaid, so a member who already settled in the app keeps their balance and the rest of the group is still cleared. Set `v_offset_opening := false` only if the 230,000 did **not** already include September. Sends nothing: `v_notify` is off, because each `notifications` row fans out to a billable SMS and the totals do not move. |
| `2026-09-29_pool_profit_3932700.sql` | **not yet run** | Raises the pool from 3,220,000 to 3,932,700 — one approved `pool_adjustments` row of +712,700, the profit the group earned before any of this was in the app. Group capital, **not** cycle earnings: `cycle_earnings()` reads `earnings_ledger` and will not see it, so a share-out will not pay it out. Aborts unless the pool is exactly 3,220,000 when it runs. |
| `2026-09-29_social_fund_290000.sql` | **not yet run** | Raises the social fund from 20,000 to 290,000 — one group-level `social_fund_entries` contribution of 270,000, `member_id` NULL. The fund sits outside `v_group_pool`, so nothing else moves. Aborts unless the fund holds exactly 20,000 when it runs. |
| `2026-09-29_meeting_loans_issued.sql` | **not yet run — run after the pool file** | Records the thirteen loans handed out at the 2026-09-26 meeting as active, disbursed loans with meeting-day repayment schedules, each pinned to a named member by phone number (name-matched only for Eva, who post-dates `scripts/seed.mjs`). Its refusal prints the full assignment, so the first run doubles as a preview to check against the minutes. They total 3,932,700 — **the whole pool to the shilling** — so the pool ends at zero and everything moves to outstanding principal; total assets and `balanced` are unchanged. Bypasses `approve_loan`, so it reports the three group rules the recording breaks and **refuses to run until `v_acknowledge_rule_breaches := true`**. |
