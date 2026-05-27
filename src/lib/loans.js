// Loan helpers (build plan §8a). Approval/schedule generation is the approve_loan
// RPC (admin side); members only read their loan and submit a request.
import { formatTZS } from './format'
import { loanCeiling } from './loanMath'
import { getApprovedSavings } from './savings'

// The member's one non-terminal loan (pending or active), if any (Decision #4).
export async function getCurrentLoan(supabase, memberId) {
  const { data, error } = await supabase
    .from('loans')
    .select('*')
    .eq('member_id', memberId)
    .in('status', ['pending', 'active'])
    .order('requested_at', { ascending: false })
    .limit(1)
    .maybeSingle()
  if (error) throw error
  return data
}

// Installment schedule for a loan, with live overdue + penalty (money view).
export async function getInstallments(supabase, loanId) {
  const { data, error } = await supabase
    .from('v_installment_status_money')
    .select('*')
    .eq('loan_id', loanId)
    .order('installment_number', { ascending: true })
  if (error) throw error
  return data
}

// Submit a loan request (build plan §8a): one-loan-at-a-time guard + 5× ceiling,
// inserted as 'pending' for admin approval.
export async function submitLoanRequest(supabase, memberId, requestedAmount) {
  const existing = await getCurrentLoan(supabase, memberId)
  if (existing) {
    throw new Error('You already have a loan in progress. Close it before requesting another.')
  }

  const totalSavings = await getApprovedSavings(supabase, memberId)
  const maxLoan = loanCeiling(totalSavings)

  if (!(requestedAmount > 0)) throw new Error('Enter a valid amount.')
  if (requestedAmount > maxLoan) {
    throw new Error(`Exceeds your 5× savings limit. Maximum eligible: ${formatTZS(maxLoan)}.`)
  }

  const { data, error } = await supabase
    .from('loans')
    .insert({ member_id: memberId, principal: requestedAmount, status: 'pending' })
    .select()
    .single()
  if (error) throw error
  return { loan: data, maxLoan, totalSavings }
}

// Admin: approve a loan + generate its 3-installment schedule atomically (build
// plan §8b). p_proof_url is the disbursement screenshot path uploaded just before.
export async function approveLoan(supabase, loanId, proofUrl) {
  const { error } = await supabase.rpc('approve_loan', { p_loan_id: loanId, p_proof_url: proofUrl })
  if (error) throw error
}

// Admin: reject a pending loan with a reason (member can re-request).
export async function rejectLoan(supabase, loanId, reason) {
  const { error } = await supabase.rpc('reject_loan', { p_loan_id: loanId, p_reason: reason })
  if (error) throw error
}
