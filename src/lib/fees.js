// Monthly fee helpers (build plan §5). Always read overdue + penalty from the money
// view, never from the base table's status (which is pending/paid only).
export async function getMyFees(supabase, memberId) {
  const { data, error } = await supabase
    .from('v_fee_status_money')
    .select('*')
    .eq('member_id', memberId)
    .order('period', { ascending: false })
  if (error) throw error
  return data
}
