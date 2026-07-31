// Withdrawals & member exit (migration 025).
//
// Money leaving the group takes two steps: 2-of-N approval authorises it, and
// mark_withdrawal_paid records the actual M-Pesa payout. The member's savings only
// move at the second step, when the proof exists.

// { savings_tzs, outstanding_tzs, locked_tzs, pool_tzs, withdrawable_tzs }.
// `locked_tzs` is the savings held as security behind an active loan — the group
// caps loans at a multiple of savings, so a borrower can't withdraw the collateral.
export async function getWithdrawable(supabase, memberId) {
  const { data, error } = await supabase.rpc('member_withdrawable', { p_member_id: memberId })
  if (error) throw error
  return (
    data?.[0] ?? {
      savings_tzs: 0,
      outstanding_tzs: 0,
      locked_tzs: 0,
      pool_tzs: 0,
      withdrawable_tzs: 0,
    }
  )
}

export async function getWithdrawals(supabase, { memberId = null, openOnly = false } = {}) {
  let q = supabase.from('withdrawal_requests').select('*').order('created_at', { ascending: false })
  if (memberId) q = q.eq('member_id', memberId)
  if (openOnly) q = q.in('status', ['pending', 'approved'])
  const { data, error } = await q
  if (error) throw error
  return data
}

export async function requestWithdrawal(supabase, amount, reason) {
  const { data, error } = await supabase.rpc('request_withdrawal', {
    p_amount: amount,
    p_reason: reason,
  })
  if (error) throw error
  return data
}

export async function approveWithdrawal(supabase, requestId) {
  const { error } = await supabase.rpc('approve_withdrawal', { p_request_id: requestId })
  if (error) throw error
}

export async function rejectWithdrawal(supabase, requestId, reason) {
  const { error } = await supabase.rpc('reject_withdrawal', {
    p_request_id: requestId,
    p_reason: reason,
  })
  if (error) throw error
}

export async function markWithdrawalPaid(supabase, requestId, proofUrl) {
  const { error } = await supabase.rpc('mark_withdrawal_paid', {
    p_request_id: requestId,
    p_proof_url: proofUrl,
  })
  if (error) throw error
}

// Admin: settle a member's whole balance and deactivate them, KEEPING their
// history. Distinct from requestMemberDeletion, which erases everything.
export async function requestMemberExit(supabase, memberId, reason) {
  const { data, error } = await supabase.rpc('request_member_exit', {
    p_member_id: memberId,
    p_reason: reason,
  })
  if (error) throw error
  return data
}
