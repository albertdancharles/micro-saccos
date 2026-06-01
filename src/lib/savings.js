// Savings helpers (build plan §3, Decision #3). There is no savings table —
// approved savings is the sum of approved savings-deposit submissions PLUS any
// admin-approved corrective adjustments (migration 013). Members can read their
// own approved adjustments (RLS policy), so this query works as a member too.
export async function getApprovedSavings(supabase, memberId) {
  const [depositsRes, adjustmentsRes] = await Promise.all([
    supabase
      .from('payment_submissions')
      .select('amount_claimed')
      .eq('member_id', memberId)
      .eq('submission_type', 'savings_deposit')
      .eq('status', 'approved'),
    supabase
      .from('savings_adjustments')
      .select('delta')
      .eq('target_member_id', memberId)
      .eq('status', 'approved'),
  ])
  if (depositsRes.error) throw depositsRes.error
  if (adjustmentsRes.error) throw adjustmentsRes.error
  const deposits = depositsRes.data.reduce((sum, r) => sum + Number(r.amount_claimed), 0)
  const adjustments = adjustmentsRes.data.reduce((sum, r) => sum + Number(r.delta), 0)
  return deposits + adjustments
}

// Sum of base monthly fees the member has actually paid. Used together with savings
// to compute the member's contribution for the 3x loan ceiling. Penalties are
// excluded — they're fines, not contributions.
export async function getPaidFeesTotal(supabase, memberId) {
  const { data, error } = await supabase
    .from('monthly_fees')
    .select('amount')
    .eq('member_id', memberId)
    .eq('status', 'paid')
  if (error) throw error
  return data.reduce((sum, r) => sum + Number(r.amount), 0)
}

// A member's total contribution = approved savings + paid monthly fees. Drives the
// 3x loan ceiling, evaluated at request time.
export async function getMemberContribution(supabase, memberId) {
  const [savings, fees] = await Promise.all([
    getApprovedSavings(supabase, memberId),
    getPaidFeesTotal(supabase, memberId),
  ])
  return { savings, fees, total: savings + fees }
}
