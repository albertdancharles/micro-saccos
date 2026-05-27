// Payment submission helpers (build plan §4, §9). The single intake for all proofs
// (Decision #3). Approval/rejection are admin RPCs (Phase 3); members only insert
// and read their own submissions.
export async function submitPayment(
  supabase,
  { memberId, submissionType, relatedId = null, amountClaimed, proofUrl },
) {
  const { data, error } = await supabase
    .from('payment_submissions')
    .insert({
      member_id: memberId,
      submission_type: submissionType,
      related_id: relatedId,
      amount_claimed: amountClaimed,
      proof_url: proofUrl,
      status: 'pending',
    })
    .select()
    .single()
  if (error) throw error
  return data
}

// Admin: approve a submission with the actual amount verified on the screenshot
// (build plan §8c, Decision #11). Flips the related fee/installment to paid, banks
// penalty = received − base, and auto-closes a loan when all installments are paid.
export async function approveSubmission(supabase, submissionId, amountReceived) {
  const { error } = await supabase.rpc('approve_submission', {
    p_submission_id: submissionId,
    p_amount_received: amountReceived,
  })
  if (error) throw error
}

// Admin: reject a pending submission with a reason (member resubmits).
export async function rejectSubmission(supabase, submissionId, reason) {
  const { error } = await supabase.rpc('reject_submission', {
    p_submission_id: submissionId,
    p_reason: reason,
  })
  if (error) throw error
}

// The member's submission history, newest first (build plan History.jsx).
export async function getMySubmissions(supabase, memberId) {
  const { data, error } = await supabase
    .from('payment_submissions')
    .select('*')
    .eq('member_id', memberId)
    .order('submitted_at', { ascending: false })
  if (error) throw error
  return data
}
