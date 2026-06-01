// Savings helpers (build plan §3, Decision #3). A member's savings is the sum of:
//   * approved savings-deposit submissions
//   * paid monthly fees (base amount only; penalties are fines, not savings)
//   * admin-approved corrective adjustments (migration 013)
// Members can read their own approved adjustments (RLS policy) and their own
// monthly fees, so this query works in both member and admin contexts.
export async function getApprovedSavings(supabase, memberId) {
  const [depositsRes, feesRes, adjustmentsRes] = await Promise.all([
    supabase
      .from('payment_submissions')
      .select('amount_claimed')
      .eq('member_id', memberId)
      .eq('submission_type', 'savings_deposit')
      .eq('status', 'approved'),
    supabase
      .from('monthly_fees')
      .select('amount')
      .eq('member_id', memberId)
      .eq('status', 'paid'),
    supabase
      .from('savings_adjustments')
      .select('delta')
      .eq('target_member_id', memberId)
      .eq('status', 'approved'),
  ])
  if (depositsRes.error) throw depositsRes.error
  if (feesRes.error) throw feesRes.error
  if (adjustmentsRes.error) throw adjustmentsRes.error
  const deposits = depositsRes.data.reduce((sum, r) => sum + Number(r.amount_claimed), 0)
  const fees = feesRes.data.reduce((sum, r) => sum + Number(r.amount), 0)
  const adjustments = adjustmentsRes.data.reduce((sum, r) => sum + Number(r.delta), 0)
  return deposits + fees + adjustments
}

// Sum of base monthly fees the member has actually paid. Kept for callers that
// want the fee component separately (e.g. Profile contributions breakdown).
export async function getPaidFeesTotal(supabase, memberId) {
  const { data, error } = await supabase
    .from('monthly_fees')
    .select('amount')
    .eq('member_id', memberId)
    .eq('status', 'paid')
  if (error) throw error
  return data.reduce((sum, r) => sum + Number(r.amount), 0)
}

// Member's total contribution equals their savings now that monthly fees are
// folded into the savings total. Drives the 3x loan ceiling, evaluated at
// request time. Kept as a thin wrapper so existing callers keep working.
export async function getMemberContribution(supabase, memberId) {
  const total = await getApprovedSavings(supabase, memberId)
  return { savings: total, fees: 0, total }
}
