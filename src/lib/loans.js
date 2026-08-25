// Loan helpers. Since the admin mandate members only READ their loan: an admin
// files it (file_loan) and two admins approve and disburse it (approve_loan).
import { maxLoan as computeMaxLoan } from './loanMath'
import { getMemberContribution } from './savings'
import { getSettings } from './settings'

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

// Admin: raise a loan on a member's behalf. The client-side ceiling check that
// used to live here is gone — not moved, deleted. It was only ever advisory (a
// disabled button), and every rule it approximated is enforced in the RPCs: both
// ceilings in approve_loan, and the one-loan-at-a-time rule now in file_loan,
// which is the first time that has actually been true in SQL.
//
// maxLoanFor below still computes the ceiling, but only to SHOW it while the admin
// types. Nothing depends on it being right.
export async function fileLoan(supabase, memberId, principal) {
  const { data, error } = await supabase.rpc('file_loan', {
    p_member_id: memberId,
    p_principal: principal,
  })
  if (error) throw error
  return data
}

// What this member could borrow today, for display next to the amount field.
export async function maxLoanFor(supabase, memberId) {
  const [contribution, poolRes, { values: settings }] = await Promise.all([
    getMemberContribution(supabase, memberId),
    supabase.from('v_group_pool').select('pool_balance_tzs').single(),
    getSettings(supabase),
  ])
  if (poolRes.error) throw poolRes.error
  const pool = Number(poolRes.data?.pool_balance_tzs ?? 0)
  const multiplier = settings.contribution_multiplier
  const fraction = settings.pool_loan_fraction
  return {
    ceiling: computeMaxLoan(contribution.total, pool, { fraction, multiplier }),
    contribution,
    pool,
    multiplier,
    fraction,
  }
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
