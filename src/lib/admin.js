// Admin data assembly (build plan §9). Admin RLS lets these queries see every row,
// so we fetch the small datasets once and join client-side (15 members → trivial).
// Returns everything the admin dashboard renders: stats, the member grid, and the
// pending loan + payment queues.
import { contributionCeiling, poolCeiling, maxLoan } from './loanMath'

const monthKey = (s) => (s ? String(s).slice(0, 7) : '')

export async function getAdminData(supabase) {
  const [profilesRes, feesRes, instRes, loansRes, subsRes, poolRes, savingsRes] = await Promise.all([
    supabase.from('profiles').select('id, full_name, role, is_active').eq('is_active', true).order('full_name'),
    supabase.from('v_fee_status_money').select('*'),
    supabase.from('v_installment_status_money').select('*'),
    supabase.from('loans').select('*'),
    supabase.from('payment_submissions').select('*').order('submitted_at', { ascending: false }),
    supabase.from('v_group_pool').select('pool_balance_tzs').single(),
    supabase
      .from('payment_submissions')
      .select('member_id, amount_claimed')
      .eq('submission_type', 'savings_deposit')
      .eq('status', 'approved'),
  ])
  for (const r of [profilesRes, feesRes, instRes, loansRes, subsRes, poolRes, savingsRes]) {
    if (r.error) throw r.error
  }

  const profiles = profilesRes.data
  const fees = feesRes.data
  const installments = instRes.data
  const loans = loansRes.data
  const subs = subsRes.data

  const profileName = Object.fromEntries(profiles.map((p) => [p.id, p.full_name]))

  // Current period = the latest fee period (ensure_current_fees made one per member).
  const currentPeriod = fees.reduce((m, f) => (f.period > m ? f.period : m), '')
  const currentMonthKey = monthKey(currentPeriod)

  const feeByMember = {}
  for (const f of fees) if (f.period === currentPeriod) feeByMember[f.member_id] = f

  const memberByLoan = Object.fromEntries(loans.map((l) => [l.id, l.member_id]))
  const currentInstByMember = {}
  for (const i of installments) {
    const memberId = memberByLoan[i.loan_id]
    if (memberId && monthKey(i.due_date) === currentMonthKey) currentInstByMember[memberId] = i
  }

  // Grid: one row per active member (admin included, Decision #1).
  const gridRows = profiles.map((p) => {
    const fee = feeByMember[p.id] || null
    const installment = currentInstByMember[p.id] || null
    const statuses = [fee?.computed_status, installment?.computed_status].filter(Boolean)
    let overall = 'pending'
    if (statuses.includes('overdue')) overall = 'overdue'
    else if (statuses.length && statuses.every((s) => s === 'paid')) overall = 'paid'
    return { id: p.id, name: p.full_name, role: p.role, fee, installment, overall }
  })

  const pool = Number(poolRes.data?.pool_balance_tzs ?? 0)
  const poolCap = poolCeiling(pool)

  // Per-member contribution = approved savings + paid base monthly fees. Drives
  // the 3x loan ceiling shown to the admin per pending loan.
  const savingsByMember = {}
  for (const r of savingsRes.data) {
    savingsByMember[r.member_id] = (savingsByMember[r.member_id] || 0) + Number(r.amount_claimed)
  }
  const paidFeesByMember = {}
  for (const f of fees) {
    if (f.status === 'paid') {
      paidFeesByMember[f.member_id] = (paidFeesByMember[f.member_id] || 0) + Number(f.amount)
    }
  }

  const feesThisPeriod = fees.filter((f) => f.period === currentPeriod)
  const pendingSubs = subs.filter((s) => s.status === 'pending')
  const pendingLoansArr = loans.filter((l) => l.status === 'pending')

  const stats = {
    pool,
    feesPaid: feesThisPeriod.filter((f) => f.status === 'paid').length,
    feesTotal: feesThisPeriod.length || profiles.length,
    activeLoans: loans.filter((l) => l.status === 'active').length,
    pendingReviews: pendingSubs.length + pendingLoansArr.length,
  }

  const pendingLoans = pendingLoansArr.map((l) => {
    const savings = savingsByMember[l.member_id] || 0
    const paidFees = paidFeesByMember[l.member_id] || 0
    const contribution = savings + paidFees
    return {
      ...l,
      memberName: profileName[l.member_id] || 'Unknown',
      contribution,
      contributionCeiling: contributionCeiling(contribution),
      poolCeiling: poolCap,
      maxEligible: maxLoan(contribution, pool),
    }
  })

  const feeById = Object.fromEntries(fees.map((f) => [f.id, f]))
  const instById = Object.fromEntries(installments.map((i) => [i.id, i]))
  const pendingPayments = pendingSubs.map((s) => {
    let suggested = Number(s.amount_claimed)
    let penalty = 0
    if (s.submission_type === 'monthly_fee' && feeById[s.related_id]) {
      suggested = Number(feeById[s.related_id].total_with_penalty)
      penalty = Number(feeById[s.related_id].penalty_due)
    } else if (s.submission_type === 'loan_installment' && instById[s.related_id]) {
      suggested = Number(instById[s.related_id].total_with_penalty)
      penalty = Number(instById[s.related_id].penalty_due)
    }
    return { ...s, memberName: profileName[s.member_id] || 'Unknown', suggested, penalty }
  })

  return { stats, gridRows, pendingLoans, pendingPayments, currentMonthKey }
}

// Admin: create a new member via the admin-create-member Edge Function (which holds
// the service-role key). Returns { email, password } — the temp credentials to share.
export async function createMember(supabase, { full_name, email, phone_number }) {
  const { data, error } = await supabase.functions.invoke('admin-create-member', {
    body: { full_name, email, phone_number },
  })
  if (error) {
    // Non-2xx responses surface as FunctionsHttpError with the Response in context.
    let message = error.message
    try {
      const ctx = await error.context?.json?.()
      if (ctx?.error) message = ctx.error
    } catch {
      /* keep the generic message */
    }
    throw new Error(message || 'Could not create the member.')
  }
  return data
}
