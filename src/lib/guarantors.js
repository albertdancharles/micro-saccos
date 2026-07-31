// Loan guarantors (migration 028).
//
// A borrower nominates co-signers on a pending loan; each accepts or declines. An
// accepted pledge locks that much of the guarantor's savings — member_withdrawable()
// reports it in `locked_tzs` alongside a borrower's own collateral, so the
// withdrawal screen needs no special case for it.

export async function getLoanGuarantors(supabase, loanId) {
  const { data, error } = await supabase
    .from('loan_guarantors')
    .select('*')
    .eq('loan_id', loanId)
    .order('created_at')
  if (error) throw error
  return data
}

// Guarantees this member has been asked for and not yet answered.
export async function getMyGuaranteeRequests(supabase, memberId) {
  const { data, error } = await supabase
    .from('loan_guarantors')
    .select('*, loans(id, principal, member_id, status)')
    .eq('guarantor_id', memberId)
    .eq('status', 'pending')
    .order('created_at')
  if (error) throw error
  return data
}

// Everything this member is currently standing behind — what their locked savings
// are actually for.
export async function getMyActiveGuarantees(supabase, memberId) {
  const { data, error } = await supabase
    .from('loan_guarantors')
    .select('*, loans(id, principal, member_id, status)')
    .eq('guarantor_id', memberId)
    .eq('status', 'accepted')
  if (error) throw error
  return (data || []).filter((g) => ['pending', 'active'].includes(g.loans?.status))
}

export async function nominateGuarantor(supabase, loanId, guarantorId, amount) {
  const { data, error } = await supabase.rpc('nominate_guarantor', {
    p_loan_id: loanId,
    p_guarantor_id: guarantorId,
    p_amount: amount,
  })
  if (error) throw error
  return data
}

export async function respondToGuarantee(supabase, guaranteeId, accept) {
  const { error } = await supabase.rpc('respond_to_guarantee', {
    p_guarantee_id: guaranteeId,
    p_accept: accept,
  })
  if (error) throw error
}

export async function cancelGuarantee(supabase, guaranteeId) {
  const { error } = await supabase.rpc('cancel_guarantee', { p_guarantee_id: guaranteeId })
  if (error) throw error
}

// Admin: recover a written-off loan from the people who backed it. Pro-rata across
// the accepted pledges and capped at each one — no guarantor pays more than they
// promised. Returns the total recovered.
export async function callGuarantees(supabase, loanId, reason) {
  const { data, error } = await supabase.rpc('call_guarantees', {
    p_loan_id: loanId,
    p_reason: reason,
  })
  if (error) throw error
  return data
}
