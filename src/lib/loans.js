// Loan helpers (build plan §8a). Approval/schedule generation is the approve_loan
// RPC (admin side); members only read their loan and submit a request.
import { formatTZS } from './format'
import { maxLoan as computeMaxLoan } from './loanMath'
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

// Submit a loan request (build plan §8a): one-loan-at-a-time guard + ceiling,
// inserted as 'pending' for admin approval. The ceiling is the lower of 5× savings
// and 25% of the group pool (so one member can't drain the pool).
export async function submitLoanRequest(supabase, memberId, requestedAmount) {
  const existing = await getCurrentLoan(supabase, memberId)
  if (existing) {
    throw new Error('You already have a loan in progress. Close it before requesting another.')
  }

  const [totalSavings, poolRes] = await Promise.all([
    getApprovedSavings(supabase, memberId),
    supabase.from('v_group_pool').select('pool_balance_tzs').single(),
  ])
  if (poolRes.error) throw poolRes.error
  const pool = Number(poolRes.data?.pool_balance_tzs ?? 0)
  const ceiling = computeMaxLoan(totalSavings, pool)

  if (!(requestedAmount > 0)) throw new Error('Enter a valid amount.')
  if (requestedAmount > ceiling) {
    throw new Error(
      `Exceeds your limit. Maximum eligible: ${formatTZS(ceiling)} (the lower of 5× your savings and 25% of the group pool).`,
    )
  }

  const { data, error } = await supabase
    .from('loans')
    .insert({ member_id: memberId, principal: requestedAmount, status: 'pending' })
    .select()
    .single()
  if (error) throw error
  return { loan: data, maxLoan: ceiling, totalSavings, pool }
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
