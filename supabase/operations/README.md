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

It is also the one file here that was overtaken by events: on 2026-10-01 the loans were filed
and approved in the app instead, one member at a time. That is the better record — a real
two-admin approval trail — and it leaves nothing for the loans file to do. What it does leave
is a wrong repayment schedule, which `2026-10-01_loans_reanchored_to_the_26_sep_meeting.sql`
corrects. That file depends on no other file in this directory: it moves dates and nothing
else, so it can run before or after the social fund file, and before or after migration 048.
It does depend on the calendar — **run it before the 31 October meeting**, because a due date
it would move into the past is a penalty nobody can avoid, and it refuses rather than write
one.

**How the two rows above were confirmed.** Not from a run log — from the live approval card on
2026-09-30. It showed a member's savings as 230,000 split 220,000 adjustment + 10,000 paid fee,
which is exactly the offset the September fee file makes, and a 25% arm of 983,175, i.e. assets of
3,932,700 where the pool stood at 3,220,000 before the profit file. The same card also shows the
loans file has **not** run: it would leave the pool at zero, and a zero pool refuses a loan under
045's liquidity check and under the older 25%-of-pool rule alike, yet the refusal that came back
was neither. `2026-09-29_social_fund_290000.sql` is still unverified — the fund sits outside
`v_group_pool`, so nothing on that card moves either way.

**Migrations to apply alongside these.** None of them are required by the files below — every
one of these runs against the schema as it stands — but each one is required by the APP once
these have run, so apply all three around the same sitting.

* `044_meeting_day_fee_due_dates.sql` — a monthly fee falls due at the meeting, not on the last
  day of the month. The September fee file records a collection made at the 26 Sep meeting;
  without 044 the app keeps showing later fees as still payable for several days after the only
  meeting at which they could have been paid.
* `045_loan_cap_on_group_assets.sql` — the loans file computes its own report either way, but
  `approve_loan` does not: until 045 lands it measures the 25% ceiling against the liquid pool,
  which this recording leaves at zero, so the next loan filed in the app would be refused for a
  reason the group did not vote for.
* `046_approval_without_proof.sql` — drops the NOT NULL on `loan_approvals.proof_url`. The app no
  longer asks an admin for a disbursement screenshot, so without 046 the very next approval fails
  in the database with a not-null violation and the admin sees the raw error. Independent of the
  files below: none of them writes a `loan_approvals` row, and the loans file records its thirteen
  loans without going through `approve_loan` at all.
* `047_contribution_counts_adjustments.sql` — **required by the savings file above, and the reason a
  real approval was blocked on 2026-09-30.** That file records the opening balances as
  `savings_adjustments` rows, which is the one table the old `approve_loan` never read: it measured
  a member holding 230,000 at the 10,000 September fee alone and refused anything over 70,000, while
  the member's dashboard and the admin's card both showed 230,000. Until 047 lands, every loan the
  group agreed in September is refused by the app. Unlike the three above, this one is needed the
  moment the savings file has run, whether or not the rest follow.
* `048_schedule_anchored_to_the_meeting.sql` — **required by the re-anchoring file below, in the sense
  that without it the same correction is needed after every meeting.** `approve_loan` counted the
  repayment schedule from the day an admin pressed approve, so a loan agreed at the 26 September
  meeting and recorded on 1 October fell due first at the *November* meeting — the October one was
  skipped. 048 counts from the meeting the money was handed over at instead, which makes the first
  installment the very next meeting however late the paperwork is. It changes newly approved loans
  only; the September batch is restated by the operations file below.

| File | When | What |
|---|---|---|
| `2026-08-25_opening_balance_reset.sql` | once, 2026-08-25 | Cleared 17 unpaid fee rows (170,000 base, 6,500 penalty) and set `penalty_rate` to 0. The group starts collecting in September 2026. |
| `2026-09-01_clear_august_fees.sql` | **never run — superseded 2026-09-15** | Would have deleted the August fee rows that `ensure_current_fees()` regenerated after the reset. Dropped because the group collected August (6 of 7 paid on 2026-09-12). Its DELETE is commented out; **do not re-enable it** — it would erase paid history. |
| `2026-09-29_savings_opening_balance_230k.sql` | once, 2026-09-29 | Credited 230,000 TZS of savings to every active member as one approved `savings_adjustments` row each — the per-member opening balances the 2026-08-25 reset deferred. Raised the pool by the same total (14 members, 3,220,000). |
| `2026-09-29_september_fee_collected.sql` | run, confirmed 2026-09-30 | Records the September 2026 fee as collected at the 26 Sep meeting and takes the same amount back off each opening balance, so savings totals and the pool do not move (230,000 = 220,000 opening + 10,000 fee). Touches only the members whose September row is still unpaid, so a member who already settled in the app keeps their balance and the rest of the group is still cleared. Set `v_offset_opening := false` only if the 230,000 did **not** already include September. Sends nothing: `v_notify` is off, because each `notifications` row fans out to a billable SMS and the totals do not move. |
| `2026-09-29_pool_profit_3932700.sql` | run, confirmed 2026-09-30 | Raises the pool from 3,220,000 to 3,932,700 — one approved `pool_adjustments` row of +712,700, the profit the group earned before any of this was in the app. Group capital, **not** cycle earnings: `cycle_earnings()` reads `earnings_ledger` and will not see it, so a share-out will not pay it out. Aborts unless the pool is exactly 3,220,000 when it runs. |
| `2026-09-29_social_fund_290000.sql` | **not yet run** | Raises the social fund from 20,000 to 290,000 — one group-level `social_fund_entries` contribution of 270,000, `member_id` NULL. The fund sits outside `v_group_pool`, so nothing else moves. Aborts unless the fund holds exactly 20,000 when it runs. |
| `2026-09-29_meeting_loans_issued.sql` | **superseded 2026-10-01 — the loans were recorded in the app instead** | Records the thirteen loans handed out at the 2026-09-26 meeting as active, disbursed loans with meeting-day repayment schedules, each pinned to a named member by phone number (name-matched only for Eva, who post-dates `scripts/seed.mjs`). Its refusal prints the full assignment, so the first run doubles as a preview to check against the minutes. They total 3,932,700 — **the whole pool to the shilling** — so the pool ends at zero and everything moves to outstanding principal; total assets and `balanced` are unchanged. Bypasses `approve_loan`, so it reports the three group rules the recording breaks and **refuses to run until `v_acknowledge_rule_breaches := true`**. **Do not run it now:** the loans were filed and approved in the app instead, member by member, so every borrower already holds an active loan and this file aborts on its own one-loan-per-member guard. Kept for the record, and for the reading of the assignment and the rule breaches it prints. What the in-app recording got wrong was the dates — see the row below. |
| `2026-10-01_loans_reanchored_to_the_26_sep_meeting.sql` | **not yet run — run before 31 October 2026** | Restates the loans recorded in the app for the 26 September meeting as what they are: requested, approved and disbursed at that meeting, with installments at the next three meetings (2026-10-31, 2026-11-28, 2026-12-26). `approve_loan` had counted the schedule from the day each loan was typed in, which put the first repayment at the November meeting and skipped October altogether. Dates only — no principal, interest, payment or balance moves, and `v_pool_reconciliation` reads the same before and after. Unlike 043's sketched backfill it moves due dates **earlier**, so it prints the whole batch and **refuses until `v_confirm := true`**; it also refuses if any installment it would move is paid, part-paid, cancelled or has a submission against it, and if any new due date has already passed — which is why it has to run before the October meeting. Silent by construction: no status changes, so no notification and no SMS. Safe to re-run; the second run finds nothing to do. |
