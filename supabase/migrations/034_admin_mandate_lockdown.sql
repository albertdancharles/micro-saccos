-- 034_admin_mandate_lockdown.sql — admins hold the mandate; members only read.
--
-- Two halves, and the second is the one that matters.
--
-- HALF ONE: members file nothing. The two INSERT policies that let a member write
-- (`loans`, `payment_submissions`) are dropped. From here every transaction is
-- keyed by an admin — see 036.
--
-- HALF TWO: make the admin gate actually hold. The gate was not merely permissive,
-- it was open. This schema contains exactly TWO `REVOKE` statements, so every other
-- function keeps Postgres' default EXECUTE TO PUBLIC — and ten SECURITY DEFINER
-- functions have no authorization check in their body at all. `execute_role_change`
-- checks only `status = 'pending'` before running `UPDATE profiles SET role`. Three
-- of the ten have their request ids handed to members by `USING (auth.uid() IS NOT
-- NULL)` SELECT policies, which closes the loop into a self-serve exploit: read a
-- pending id, apply it. A member could promote themselves to admin. A borrower
-- could write off their own loan. None of that needed a bug — just the documented
-- default privilege nobody revoked.
--
-- The `execute_*` family was always meant to be internal; every one of them carries
-- a comment saying "never call directly from the client" (setup.sql:1188, 2469,
-- 2250, 1923). Comments are not privileges. This migration writes the REVOKEs those
-- comments assumed.
--
-- Requires 033.

-- --------------------------------------------------------------------------
-- 1. The gate itself.
--
--    is_admin() was the only SECURITY DEFINER function in the schema without a
--    pinned search_path, and the only admin-counting query that did not check
--    is_active — required_approvals() and execute_role_change both do. So a
--    deactivated admin, or one mid-removal, still passed every RLS policy and
--    every RPC guard in the app.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
     WHERE id = auth.uid() AND role = 'admin' AND is_active = true
  );
$$;

-- Companion for the member-read policies below. "Signed in" is not the same as
-- "a member of this group": a pending or removed profile still holds a valid JWT.
CREATE OR REPLACE FUNCTION is_active_member()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND is_active = true
  );
$$;

-- --------------------------------------------------------------------------
-- 2. Revoke the ten unguarded SECURITY DEFINER functions.
--
--    No function body changes. Each is reached only via PERFORM from inside its
--    matching approve_* (which is SECURITY DEFINER and runs as owner) or, for
--    send_due_reminders, from pg_cron as superuser. Both callers are unaffected by
--    a revoke — only the direct client path dies, which is the whole point.
--
--    REVOKING FROM `PUBLIC` ALONE IS NOT ENOUGH ON SUPABASE, and this is the trap
--    the existing code fell into. Supabase ships
--        ALTER DEFAULT PRIVILEGES IN SCHEMA public
--          GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;
--    so every function these migrations create is granted to `authenticated`
--    EXPLICITLY, on top of the implicit PUBLIC grant. Dropping PUBLIC leaves the
--    explicit grant standing and the function still reachable through PostgREST.
--    032's `REVOKE ALL ON FUNCTION schedule_notification_drain FROM public` and its
--    comment ("`authenticated` is never granted EXECUTE") are wrong for exactly
--    this reason; it is corrected below.
--
--    Naming all three is the only form that actually closes the door. The SQL test
--    harness reproduces Supabase's grants faithfully (fixtures.sql), which is what
--    caught this.
-- --------------------------------------------------------------------------

REVOKE ALL ON FUNCTION execute_member_deletion(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_savings_edit(uuid)    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_pool_edit(uuid)       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_role_change(uuid)     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_setting_change(uuid)  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_loan_action(uuid)     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_cycle_close(uuid)     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION execute_social_grant(uuid)    FROM PUBLIC, anon, authenticated;

-- Not an execute_* but the same shape of hole: arbitrary title/body to any
-- recipient on the sms channel — metered spend, and a phishing channel that
-- arrives looking like a trusted group message.
REVOKE ALL ON FUNCTION enqueue_delivery(uuid, text, text, uuid, text)
  FROM PUBLIC, anon, authenticated;

-- Fans a full reminder sweep out to the whole group on demand. pg_cron still
-- calls it; a member no longer can.
REVOKE ALL ON FUNCTION send_due_reminders() FROM PUBLIC, anon, authenticated;

-- 032 intended this one to be unreachable and said so in a comment. Make it true.
REVOKE ALL ON FUNCTION schedule_notification_drain(text, text, text)
  FROM PUBLIC, anon, authenticated;

-- --------------------------------------------------------------------------
-- 3. Close the 2-of-N bypass on roles.
--
--    `CREATE POLICY "Admin can update any profile" ON profiles FOR UPDATE
--     USING (is_admin())` has no WITH CHECK, so Postgres reuses USING as the
--    check — which is caller-scoped, not row-scoped. Any single admin could
--    `update profiles set role='admin'` straight from the browser client and skip
--    request_role_change -> approve_role_change entirely. The whole 2-of-N
--    apparatus for role changes was bypassable by exactly the population it exists
--    to constrain.
--
--    A WITH CHECK cannot fix this: RLS check expressions cannot see OLD, so the
--    policy has no way to say "role must not change". The privilege system can.
--    No client code writes profiles directly — every `.from('profiles')` in src/ is
--    a .select(), and all seven SQL writers are SECURITY DEFINER functions running
--    as owner (update_own_profile, update_own_phone, update_notification_prefs,
--    execute_role_change, approve_member, request_member_exit, the 026 backfill).
--    So revoking UPDATE from `authenticated` outright costs nothing and closes it.
-- --------------------------------------------------------------------------

REVOKE UPDATE ON profiles FROM authenticated;

-- The policy is deliberately left in place. It is now unreachable — the missing
-- GRANT is the real gate, not the policy — but if a future feature grants column
-- level UPDATE back (say admins editing member KYC in the UI), RLS must already be
-- correct underneath it. Do NOT grant role or is_active: those belong to the voted
-- RPCs alone.
COMMENT ON TABLE profiles IS
  'UPDATE is revoked from `authenticated` (034). All writes go through SECURITY DEFINER RPCs. Never grant UPDATE on role or is_active — they are governed by request_role_change / approve_role_change (2-of-N) and approve_member.';

-- --------------------------------------------------------------------------
-- 4. Members file nothing.
--
--    These were the only two INSERT policies a member had on a money table, and
--    both were loose beyond the member-scoping: the loans policy constrained only
--    member_id and status, so any principal was insertable (the cap lives in
--    approve_loan) and the one-open-loan rule was client-side only. The
--    payment_submissions policy never bound related_id to member_id, so a member
--    could file a pending submission against ANOTHER member's fee and block their
--    real payment with "already under review".
--
--    Both problems disappear with the policies.
-- --------------------------------------------------------------------------

DROP POLICY IF EXISTS "Member inserts loan request"   ON loans;
DROP POLICY IF EXISTS "Member inserts own submission" ON payment_submissions;

-- SELECT policies stay: members still see their own loans and submissions.

-- --------------------------------------------------------------------------
-- 5. "Signed in" is not "a member".
--
--    Thirteen tables were readable by anyone holding a JWT, including a pending
--    or deactivated profile — group settings, cycles, distributions, every
--    withdrawal request, meeting minutes, the social fund. Self-registration is
--    being removed in this same release, but is_active=false also covers exited
--    and suspended members, so the scoping matters regardless.
--
--    Group transparency is deliberate and preserved: an ACTIVE member still reads
--    all of this, plus the member directory, income statement and balance sheet.
-- --------------------------------------------------------------------------

DROP POLICY IF EXISTS "Everyone reads group settings" ON group_settings;
CREATE POLICY "Active members read group settings" ON group_settings
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads setting changes" ON setting_changes;
CREATE POLICY "Active members read setting changes" ON setting_changes
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads earnings" ON earnings_ledger;
CREATE POLICY "Active members read earnings" ON earnings_ledger
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads cycles" ON cycles;
CREATE POLICY "Active members read cycles" ON cycles
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads distributions" ON distributions;
CREATE POLICY "Active members read distributions" ON distributions
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads cycle closures" ON cycle_closures;
CREATE POLICY "Active members read cycle closures" ON cycle_closures
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads withdrawals" ON withdrawal_requests;
CREATE POLICY "Active members read withdrawals" ON withdrawal_requests
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads meetings" ON meetings;
CREATE POLICY "Active members read meetings" ON meetings
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads attendance" ON meeting_attendance;
CREATE POLICY "Active members read attendance" ON meeting_attendance
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads social fund" ON social_fund_entries;
CREATE POLICY "Active members read social fund" ON social_fund_entries
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Everyone reads grant requests" ON social_fund_grant_requests;
CREATE POLICY "Active members read grant requests" ON social_fund_grant_requests
  FOR SELECT USING (is_active_member() OR is_admin());

DROP POLICY IF EXISTS "Anyone signed in reads templates" ON notification_templates;
CREATE POLICY "Active members read templates" ON notification_templates
  FOR SELECT USING (is_active_member() OR is_admin());

-- loan_guarantors is intentionally not re-scoped here; 035 drops the table.

-- --------------------------------------------------------------------------
-- 6. The read RPCs and views that leaked past the base-table RLS.
--
--    Every read RPC is SECURITY DEFINER, so the caller's RLS never applies; the
--    in-body check IS the scope. Only member_ledger (029) ever had one. The rest
--    returned whole-group per-member financials to anybody signed in.
--
--    What stays open to members is a deliberate choice, not an oversight:
--    group_member_directory (savings + loan per member), group_income_statement
--    and group_balance_sheet. This group runs on transparency; losing the ability
--    to file a transaction is not the same as losing sight of the books.
--
--    What closes is per-member operational detail with no transparency purpose:
--    another member's withdrawable balance, the per-member cycle basis, the
--    share-out preview, and the whole-group member report.
-- --------------------------------------------------------------------------

-- cycle_earnings, preview_cycle_close and group_member_report are deliberately
-- LEFT OPEN to members. They are read-only, carry no PII, and sit inside the
-- transparency envelope this group has chosen: if the income statement and balance
-- sheet are open, a cycle's earnings and the share-out preview that follows from
-- them are not a secret. They are also called straight from the browser
-- (src/lib/cycles.js:28,36, src/lib/reports.js:24), so a REVOKE here would break
-- /admin/cycles and /admin/reports rather than protect anything.
--
-- member_withdrawable is the exception — one member's withdrawable balance is
-- operational detail about them, not group transparency. It gets a self-or-admin
-- guard in 035, which has to rewrite its body anyway to drop the guarantor term.

-- Per-member views that ran as owner (RLS-bypassing) and were granted to every
-- authenticated user. 027 set security_invoker on four member-scoped views and
-- missed these two — same class of bug, same fix.
ALTER VIEW v_member_capital_events SET (security_invoker = true);
ALTER VIEW v_loan_risk             SET (security_invoker = true);

-- --------------------------------------------------------------------------
-- 7. Retire whatever is still in flight.
--
--    Members can no longer file, so anything already pending would sit in the
--    admin queue forever with no way for its author to withdraw or amend it.
--    Reject it explicitly and tell each member why, rather than leaving rows
--    stranded in a queue that no longer has an intake.
--
--    Admins re-key any of these that were genuine, through the new flows in 036.
-- --------------------------------------------------------------------------

INSERT INTO notification_templates (kind, lang, title, body) VALUES
  ('intake_superseded', 'sw', 'Ombi lako limefungwa',
   'Malipo na maombi sasa yanaandikwa na msimamizi. Wasiliana na msimamizi wako.'),
  ('intake_superseded', 'en', 'Your request was closed',
   'Payments and requests are now recorded by an admin. Please speak to your admin.')
ON CONFLICT (kind, lang) DO UPDATE
  SET title = EXCLUDED.title, body = EXCLUDED.body;

DO $$
DECLARE
  v_reason text := 'Superseded — payments are now recorded by admins.';
  v_subs   int;
  v_loans  int;
  v_wdr    int;
BEGIN
  -- Notify first, off the rows we are about to change, so each member gets one
  -- message per stranded item. 033's BEFORE INSERT trigger renders it in their
  -- own language from the templates above.
  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT member_id, 'intake_superseded', 'Your request was closed', NULL,
         jsonb_build_object('source', 'payment_submission', 'id', id)
    FROM payment_submissions WHERE status = 'pending';

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT member_id, 'intake_superseded', 'Your request was closed', NULL,
         jsonb_build_object('source', 'loan', 'id', id)
    FROM loans WHERE status = 'pending';

  INSERT INTO notifications (recipient_id, kind, title, body, data)
  SELECT member_id, 'intake_superseded', 'Your request was closed', NULL,
         jsonb_build_object('source', 'withdrawal_request', 'id', id)
    FROM withdrawal_requests WHERE status = 'pending';

  UPDATE payment_submissions
     SET status = 'rejected', reviewed_at = now(), rejection_reason = v_reason
   WHERE status = 'pending';
  GET DIAGNOSTICS v_subs = ROW_COUNT;

  UPDATE loans
     SET status = 'rejected', rejection_reason = v_reason
   WHERE status = 'pending';
  GET DIAGNOSTICS v_loans = ROW_COUNT;

  UPDATE withdrawal_requests
     SET status = 'rejected', rejection_reason = v_reason
   WHERE status = 'pending';
  GET DIAGNOSTICS v_wdr = ROW_COUNT;

  INSERT INTO audit_log (actor_id, action, target_type, target_id, details)
  VALUES (NULL, 'admin_mandate_lockdown', 'migration', NULL,
          jsonb_build_object('submissions_rejected', v_subs,
                             'loans_rejected',       v_loans,
                             'withdrawals_rejected', v_wdr));
END;
$$;
