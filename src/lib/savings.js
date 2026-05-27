// Savings helpers (build plan §3, Decision #3). There is no savings table —
// approved savings is the sum of approved savings-deposit submissions.
export async function getApprovedSavings(supabase, memberId) {
  const { data, error } = await supabase
    .from('payment_submissions')
    .select('amount_claimed')
    .eq('member_id', memberId)
    .eq('submission_type', 'savings_deposit')
    .eq('status', 'approved')
  if (error) throw error
  return data.reduce((sum, r) => sum + Number(r.amount_claimed), 0)
}
