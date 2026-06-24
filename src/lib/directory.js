// Group transparency directory (migration 019). Returns one row per active member
// with their savings balance and active-loan outstanding — the figures every
// member is allowed to see about every other member. Backed by the
// group_member_directory() SECURITY DEFINER function, so base-table RLS (which
// scopes members to their own rows) doesn't block the cross-member read, and no
// PII (phone, NIDA, next-of-kin, proof screenshots) is ever exposed.
export async function getMemberDirectory(supabase) {
  const { data, error } = await supabase.rpc('group_member_directory')
  if (error) throw error
  return (data || []).map((r) => ({
    id: r.member_id,
    name: r.full_name,
    role: r.role,
    savings: Number(r.savings_tzs) || 0,
    loanBalance: Number(r.active_loan_tzs) || 0,
    hasActiveLoan: !!r.has_active_loan,
  }))
}
