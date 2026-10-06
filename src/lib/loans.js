// Loan helpers. Since the admin mandate members only READ their loan: an admin
// files it (file_loan) and two admins approve and disburse it (approve_loan).
import { maxLoan as computeMaxLoan } from './loanMath'
import { getMemberContribution } from './savings'
import { getSettings } from './settings'
// todayEAT lives in fees.js because that is where the group's "what counts as
// today" rule is written down and tested. installmentsDueNow below has to answer
// the same question about the same calendar, so it borrows it rather than keeping
// a second copy that could drift.
import { todayEAT } from './fees'

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

// The installments that count toward "amount due" today.
//
// THE SAME RULE AS feesDueNow, AND FOR THE SAME REASON. A repayment is handed over
// at the monthly meeting and nowhere else, and since migration 043 the due date IS
// that meeting — so before it the money is owed for the month but there has been no
// occasion to pay it.
//
// What this replaces: "overdue, or falling in the current month". That counted the
// whole installment from the 1st, which put a red AMOUNT DUE on the dashboard for
// four weeks over money the member could not hand over until the last Saturday —
// while the membership fee falling due at that very same meeting stayed out of the
// number, because fees already waited for their due date. One meeting, two
// obligations, two different answers, and no reason for the difference.
//
// Note the rule is the due date, not the status: an overdue installment is by
// definition already past it, and a part-paid one is caught by the same comparison.
// Cancelled installments are historical (022) and never an obligation.
//
// What is coming still shows in the repayment schedule and in "This month" under
// the card. This governs only the number that claims to be owed right now.
export function installmentsDueNow(installments, today = todayEAT()) {
  return (installments || []).filter(
    (i) =>
      i.computed_status !== 'paid' && i.computed_status !== 'cancelled' && i.due_date <= today,
  )
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
//
// Reads v_group_assets, not v_group_pool: since 045 the fraction is a share of
// what the group is worth, which does not move when the group lends. `pool`
// comes back too, because approve_loan will also refuse anything the pool
// cannot actually cover — a ceiling the group can't hand over is worth showing.
export async function maxLoanFor(supabase, memberId) {
  const [contribution, assetsRes, { values: settings }] = await Promise.all([
    getMemberContribution(supabase, memberId),
    supabase.from('v_group_assets').select('pool_balance_tzs, total_assets_tzs').single(),
    getSettings(supabase),
  ])
  if (assetsRes.error) throw assetsRes.error
  const pool = Number(assetsRes.data?.pool_balance_tzs ?? 0)
  const totalAssets = Number(assetsRes.data?.total_assets_tzs ?? 0)
  const multiplier = settings.contribution_multiplier
  const fraction = settings.pool_loan_fraction
  return {
    ceiling: computeMaxLoan(contribution.total, totalAssets, { fraction, multiplier }),
    contribution,
    pool,
    totalAssets,
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
