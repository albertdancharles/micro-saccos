-- 003_rls_policies.sql — Row-Level Security (build plan §6).
-- Privileged writes (fee generation, loan/payment approval) go through the service
-- role (Edge Function) or SECURITY DEFINER RPCs, so base tables need no write policy
-- for those paths.

-- Helper: is the current user an admin? SECURITY DEFINER bypasses RLS → no recursion.
CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  );
$$ LANGUAGE sql SECURITY DEFINER;

-- profiles
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Members see own profile, admin sees all"
  ON profiles FOR SELECT USING (id = auth.uid() OR is_admin());
CREATE POLICY "Admin can update any profile"
  ON profiles FOR UPDATE USING (is_admin());

-- monthly_fees (rows created by Edge Function via service role; status flipped by RPC)
ALTER TABLE monthly_fees ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Member sees own fees"
  ON monthly_fees FOR SELECT USING (member_id = auth.uid() OR is_admin());

-- loans
ALTER TABLE loans ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Member sees own loans"
  ON loans FOR SELECT USING (member_id = auth.uid() OR is_admin());
CREATE POLICY "Member inserts loan request"
  ON loans FOR INSERT WITH CHECK (member_id = auth.uid() AND status = 'pending');
-- approval/rejection happen via approve_loan / reject_loan RPCs

-- loan_installments (created + flipped by RPC only)
ALTER TABLE loan_installments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Member sees own installments via loan"
  ON loan_installments FOR SELECT USING (
    loan_id IN (SELECT id FROM loans WHERE member_id = auth.uid()) OR is_admin()
  );

-- payment_submissions
ALTER TABLE payment_submissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Member sees own submissions"
  ON payment_submissions FOR SELECT USING (member_id = auth.uid() OR is_admin());
CREATE POLICY "Member inserts own submission"
  ON payment_submissions FOR INSERT WITH CHECK (member_id = auth.uid() AND status = 'pending');
-- approval/rejection happen via approve_submission / reject_submission RPCs

-- Views: aggregate pool is safe for all authenticated users; status/money views rely
-- on the underlying table RLS (security_invoker default) so members see only their rows.
GRANT SELECT ON v_group_pool TO authenticated;
GRANT SELECT ON v_fee_status, v_fee_status_money,
                v_installment_status, v_installment_status_money TO authenticated;
