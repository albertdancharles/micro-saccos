// Chart data helpers (Phase 4). Series are computed client-side from existing
// tables — no new views or rollup tables — and bucketed by month so the charts
// stay readable for a small group.

const monthKey = (s) => (s ? String(s).slice(0, 7) : '')

// Builds a monthly running-total series of the group pool from raw transactions.
// Pool delta sources mirror v_group_pool:
//   + approved savings_deposit submissions
//   + paid monthly fees (amount + penalty_collected)
//   + paid loan installments (total_due + penalty_collected)
//   − disbursed loan principal (status in active/closed)
export async function getPoolHistory(supabase) {
  const [savingsRes, feesRes, instRes, loansRes] = await Promise.all([
    supabase
      .from('payment_submissions')
      .select('submitted_at, amount_claimed')
      .eq('submission_type', 'savings_deposit')
      .eq('status', 'approved'),
    supabase
      .from('monthly_fees')
      .select('paid_at, amount, penalty_collected')
      .eq('status', 'paid'),
    supabase
      .from('loan_installments')
      .select('paid_at, total_due, penalty_collected')
      .eq('status', 'paid'),
    supabase
      .from('loans')
      .select('disbursed_at, principal, status')
      .in('status', ['active', 'closed']),
  ])
  for (const r of [savingsRes, feesRes, instRes, loansRes]) {
    if (r.error) throw r.error
  }

  const deltaByMonth = new Map()
  const add = (when, delta) => {
    const m = monthKey(when)
    if (!m) return
    deltaByMonth.set(m, (deltaByMonth.get(m) || 0) + Number(delta))
  }

  for (const r of savingsRes.data) add(r.submitted_at, +r.amount_claimed)
  for (const r of feesRes.data) add(r.paid_at, +r.amount + Number(r.penalty_collected || 0))
  for (const r of instRes.data) add(r.paid_at, +r.total_due + Number(r.penalty_collected || 0))
  for (const r of loansRes.data) add(r.disbursed_at, -Number(r.principal))

  const months = [...deltaByMonth.keys()].sort()
  let running = 0
  return months.map((m) => {
    running += deltaByMonth.get(m)
    return { month: m, pool: Math.round(running) }
  })
}

// Builds a monthly cumulative savings series for one member.
export async function getSavingsHistory(supabase, memberId) {
  const { data, error } = await supabase
    .from('payment_submissions')
    .select('submitted_at, amount_claimed')
    .eq('member_id', memberId)
    .eq('submission_type', 'savings_deposit')
    .eq('status', 'approved')
    .order('submitted_at', { ascending: true })
  if (error) throw error

  const deltaByMonth = new Map()
  for (const r of data) {
    const m = monthKey(r.submitted_at)
    if (!m) continue
    deltaByMonth.set(m, (deltaByMonth.get(m) || 0) + Number(r.amount_claimed))
  }
  const months = [...deltaByMonth.keys()].sort()
  let running = 0
  return months.map((m) => {
    running += deltaByMonth.get(m)
    return { month: m, savings: running }
  })
}
