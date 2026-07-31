// Loan distress actions (migration 022). Each is 2-of-N: the requester's vote does
// NOT auto-count, and no admin may open or approve an action against their own loan.
//
//   restructure           re-cut the schedule over a new term against the current
//                         outstanding principal (cancels the untouched installments,
//                         which also stops their penalty clock)
//   write_off             recognise the loss — outstanding → 0, pool absorbs it
//   recover_from_savings   settle part of the debt against the borrower's savings

export const LOAN_ACTIONS = ['restructure', 'write_off', 'recover_from_savings']

export async function requestLoanAction(
  supabase,
  loanId,
  action,
  reason,
  { amount = null, termMonths = null } = {},
) {
  const { data, error } = await supabase.rpc('request_loan_action', {
    p_loan_id: loanId,
    p_action: action,
    p_reason: reason,
    p_amount: amount,
    p_term_months: termMonths,
  })
  if (error) throw error
  return data
}

export async function approveLoanAction(supabase, actionId) {
  const { error } = await supabase.rpc('approve_loan_action', { p_action_id: actionId })
  if (error) throw error
}

export async function cancelLoanAction(supabase, actionId) {
  const { error } = await supabase.rpc('cancel_loan_action', { p_action_id: actionId })
  if (error) throw error
}
