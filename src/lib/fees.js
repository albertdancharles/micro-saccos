// Monthly fee helpers (build plan §5). Always read overdue + penalty from the money
// view, never from the base table's status (which is pending/paid only).

// Today in EAT as 'YYYY-MM-DD', so it compares directly against the DB's date
// strings. The browser's own midnight is the wrong one — a member opening the app
// late on the 25th in a UTC-6 timezone is already on the 26th in Dar es Salaam, and
// that is the day the group's rules are written in. en-CA formats as YYYY-MM-DD;
// same stance as the EAT rendering in AuditLog.jsx.
export const todayEAT = () =>
  new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Dar_es_Salaam' }).format(new Date())

// The fees that count toward "amount due" today.
//
// A fee counts only once its due date has ARRIVED. Fees are handed over at the
// monthly meeting and nowhere else, and since migration 044 the due date IS that
// meeting — so before it, the money is owed for the month but there has been no
// occasion to pay it. Counting it early puts a red "amount due" on the dashboard
// for the first three weeks of every month over something the member cannot act
// on, which is how a member ends up believing they are in arrears when they are
// not. What is coming still shows in the fee list under the card; this governs
// only the number that claims to be owed right now.
//
// Note the rule is the due date, not the status: an overdue fee is by definition
// already past it, and a part-paid one is caught by the same comparison.
export function feesDueNow(fees, today = todayEAT()) {
  return (fees || []).filter((f) => f.computed_status !== 'paid' && f.due_date <= today)
}
export async function getMyFees(supabase, memberId) {
  const { data, error } = await supabase
    .from('v_fee_status_money')
    .select('*')
    .eq('member_id', memberId)
    .order('period', { ascending: false })
  if (error) throw error
  return data
}
