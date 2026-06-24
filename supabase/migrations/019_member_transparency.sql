-- 019_member_transparency.sql — group transparency directory (member-facing).
--
-- The group now operates on full mutual transparency: every active member can see
-- every other member's savings balance and outstanding loan. Base-table RLS keeps
-- each member scoped to their own rows (003_rls_policies.sql), so this SECURITY
-- DEFINER function does the per-member aggregation server-side and returns ONLY
-- non-sensitive financial summaries. It deliberately omits phone numbers, NIDA,
-- next-of-kin, emails, and payment-proof screenshots — those stay private.
--
-- Savings mirrors lib/savings.js getApprovedSavings(): approved savings deposits
-- + paid monthly-fee base amounts + admin-approved corrective adjustments.
-- Active loan mirrors v_group_assets: outstanding_principal of the active loan
-- (falling back to principal for loans that pre-date migration 011).

CREATE OR REPLACE FUNCTION group_member_directory()
RETURNS TABLE (
  member_id       uuid,
  full_name       text,
  role            text,
  savings_tzs     numeric,
  active_loan_tzs numeric,
  has_active_loan boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p.id,
    p.full_name,
    p.role,
    COALESCE(dep.total, 0) + COALESCE(fee.total, 0) + COALESCE(adj.total, 0) AS savings_tzs,
    COALESCE(ln.outstanding, 0)                                              AS active_loan_tzs,
    ln.outstanding IS NOT NULL                                              AS has_active_loan
  FROM profiles p
  LEFT JOIN LATERAL (
    SELECT SUM(amount_claimed) AS total
    FROM payment_submissions
    WHERE member_id = p.id
      AND submission_type = 'savings_deposit'
      AND status = 'approved'
  ) dep ON true
  LEFT JOIN LATERAL (
    SELECT SUM(amount) AS total
    FROM monthly_fees
    WHERE member_id = p.id AND status = 'paid'
  ) fee ON true
  LEFT JOIN LATERAL (
    SELECT SUM(delta) AS total
    FROM savings_adjustments
    WHERE target_member_id = p.id AND status = 'approved'
  ) adj ON true
  LEFT JOIN LATERAL (
    SELECT SUM(COALESCE(outstanding_principal, principal)) AS outstanding
    FROM loans
    WHERE member_id = p.id AND status = 'active'
  ) ln ON true
  WHERE p.is_active = true
  ORDER BY p.full_name;
$$;

-- Any signed-in member may call it; anonymous users may not. The function body
-- reveals no PII, so member-level access is the intended transparency.
REVOKE ALL ON FUNCTION group_member_directory() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION group_member_directory() TO authenticated;
