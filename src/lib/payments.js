// Payment intake. Still the single table for every payment (Decision #3), but the
// direct member INSERT is gone — 034 dropped the policy that allowed it, so these
// all go through admin RPCs now.

// Record one payment for a member. Casts the recording admin's signature too, and
// settles immediately if that already meets the row's threshold: one signature for
// another member's monthly fee, two for a savings deposit or a repayment, and two
// always for the admin's own money.
export async function recordPayment(
  supabase,
  { memberId, submissionType, relatedId = null, amount, proofUrl = null },
) {
  const { data, error } = await supabase.rpc('record_payment', {
    p_member_id: memberId,
    p_type: submissionType,
    p_related_id: relatedId,
    p_amount: amount,
    p_proof_url: proofUrl,
  })
  if (error) throw error
  return data
}

// Post a whole month of fees at once. Entries are { fee_id, amount, proof_url }.
// All-or-nothing: one bad entry rolls the batch back, so the admin never has to
// work out which half of the sheet posted.
export async function recordFeePayments(supabase, entries) {
  const { data, error } = await supabase.rpc('record_fee_payments', { p_entries: entries })
  if (error) throw error
  return data
}

// Corrections (037). A void reverses the exact amounts the waterfall allocated,
// rather than recomputing them — a penalty recomputed at void time would use
// today's date and give a different answer from the one that was banked.
export async function requestPaymentVoid(supabase, submissionId, reason) {
  const { data, error } = await supabase.rpc('request_payment_void', {
    p_submission_id: submissionId,
    p_reason: reason,
  })
  if (error) throw error
  return data
}

export async function approvePaymentVoid(supabase, voidId) {
  const { error } = await supabase.rpc('approve_payment_void', { p_void_id: voidId })
  if (error) throw error
}

export async function cancelPaymentVoid(supabase, voidId) {
  const { error } = await supabase.rpc('cancel_payment_void', { p_void_id: voidId })
  if (error) throw error
}

// Why this entry cannot be voided, or null when it can. Lets the UI explain
// itself up front instead of failing at the end of a two-signature round trip.
export async function paymentVoidBlocker(supabase, submissionId) {
  const { data, error } = await supabase.rpc('payment_void_blocker', {
    p_submission_id: submissionId,
  })
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
