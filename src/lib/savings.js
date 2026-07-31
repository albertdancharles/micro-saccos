// Savings helpers (build plan §3, Decision #3). A member's savings is the sum of:
//   * approved savings-deposit submissions
//   * monthly fee money actually banked (base only; penalties are fines, not savings)
//   * admin-approved corrective adjustments (migration 013), including the negative
//     ones a loan recovery creates (migration 022)
// Members can read their own approved adjustments (RLS policy) and their own
// monthly fees, so this query works in both member and admin contexts.
//
// Since partial payments (migration 021) the fee component is amount_paid across
// EVERY fee row, not `amount` on rows marked 'paid' — otherwise a member who is
// halfway through settling a fee has that money vanish from their savings.
export async function getApprovedSavings(supabase, memberId) {
  const [depositsRes, feesRes, adjustmentsRes] = await Promise.all([
    supabase
      .from('payment_submissions')
      .select('amount_claimed')
      .eq('member_id', memberId)
      .eq('submission_type', 'savings_deposit')
      .eq('status', 'approved'),
    supabase.from('monthly_fees').select('amount_paid').eq('member_id', memberId),
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
  const fees = feesRes.data.reduce((sum, r) => sum + Number(r.amount_paid), 0)
  const adjustments = adjustmentsRes.data.reduce((sum, r) => sum + Number(r.delta), 0)
  return deposits + fees + adjustments
}

// Sum of monthly fee money the member has actually banked. Kept for callers that
// want the fee component separately (e.g. Profile contributions breakdown).
export async function getPaidFeesTotal(supabase, memberId) {
  const { data, error } = await supabase
    .from('monthly_fees')
    .select('amount_paid')
    .eq('member_id', memberId)
  if (error) throw error
  return data.reduce((sum, r) => sum + Number(r.amount_paid), 0)
}

// Member's total contribution equals their savings now that monthly fees are
// folded into the savings total. Drives the 3x loan ceiling, evaluated at
// request time. Kept as a thin wrapper so existing callers keep working.
export async function getMemberContribution(supabase, memberId) {
  const total = await getApprovedSavings(supabase, memberId)
  return { savings: total, fees: 0, total }
}
