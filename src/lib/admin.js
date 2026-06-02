// Admin data assembly (build plan §9). Admin RLS lets these queries see every row,
// so we fetch the small datasets once and join client-side (15 members → trivial).
// Returns everything the admin dashboard renders: stats, the member grid, and the
// pending loan + payment queues.
import { contributionCeiling, poolCeiling, maxLoan } from './loanMath'

const monthKey = (s) => (s ? String(s).slice(0, 7) : '')

export async function getAdminData(supabase, currentAdminId = null) {
  const [
    profilesRes,
    feesRes,
    instRes,
    loansRes,
    subsRes,
    poolRes,
    savingsRes,
    subApprovalsRes,
    loanApprovalsRes,
    deletionRequestsRes,
    deletionApprovalsRes,
    savingsEditsRes,
    approvedAdjustmentsRes,
    savingsEditApprovalsRes,
    poolEditsRes,
    poolEditApprovalsRes,
    roleChangeRequestsRes,
    roleChangeApprovalsRes,
  ] = await Promise.all([
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
    supabase.from('submission_approvals').select('*').order('approved_at', { ascending: true }),
    supabase.from('loan_approvals').select('*').order('approved_at', { ascending: true }),
    supabase
      .from('deletion_requests')
      .select('*')
      .eq('status', 'pending')
      .order('created_at', { ascending: true }),
    supabase.from('deletion_approvals').select('*').order('approved_at', { ascending: true }),
    supabase
      .from('savings_adjustments')
      .select('*')
      .eq('status', 'pending')
      .order('created_at', { ascending: true }),
    supabase
      .from('savings_adjustments')
      .select('target_member_id, delta')
      .eq('status', 'approved'),
    supabase
      .from('savings_adjustment_approvals')
      .select('*')
      .order('approved_at', { ascending: true }),
    supabase
      .from('pool_adjustments')
      .select('*')
      .eq('status', 'pending')
      .order('created_at', { ascending: true }),
    supabase
      .from('pool_adjustment_approvals')
      .select('*')
      .order('approved_at', { ascending: true }),
    supabase
      .from('role_change_requests')
      .select('*')
      .eq('status', 'pending')
      .order('created_at', { ascending: true }),
    supabase
      .from('role_change_approvals')
      .select('*')
      .order('approved_at', { ascending: true }),
  ])
  for (const r of [
    profilesRes,
    feesRes,
    instRes,
    loansRes,
    subsRes,
    poolRes,
    savingsRes,
    subApprovalsRes,
    loanApprovalsRes,
    deletionRequestsRes,
    deletionApprovalsRes,
    savingsEditsRes,
    approvedAdjustmentsRes,
    savingsEditApprovalsRes,
    poolEditsRes,
    poolEditApprovalsRes,
    roleChangeRequestsRes,
    roleChangeApprovalsRes,
  ]) {
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

  const pool = Number(poolRes.data?.pool_balance_tzs ?? 0)
  const poolCap = poolCeiling(pool)
  // Total group assets = liquid pool + everything still owed by active borrowers.
  // outstanding_principal falls back to principal for older active loans that
  // pre-date migration 011.
  const outstandingLoans = loans
    .filter((l) => l.status === 'active')
    .reduce((s, l) => s + Number(l.outstanding_principal ?? l.principal ?? 0), 0)
  const totalAssets = pool + outstandingLoans

  // Per-member savings now includes deposits, paid monthly fees, and any
  // admin-approved corrective adjustments. Drives the 3x loan ceiling and the
  // grid/deletion/edit displays. paidFeesByMember is kept separately for any
  // breakdown that still wants to call out the fee component.
  const savingsByMember = {}
  for (const r of savingsRes.data) {
    savingsByMember[r.member_id] = (savingsByMember[r.member_id] || 0) + Number(r.amount_claimed)
  }
  const paidFeesByMember = {}
  for (const f of fees) {
    if (f.status === 'paid') {
      paidFeesByMember[f.member_id] = (paidFeesByMember[f.member_id] || 0) + Number(f.amount)
      savingsByMember[f.member_id] = (savingsByMember[f.member_id] || 0) + Number(f.amount)
    }
  }
  for (const r of approvedAdjustmentsRes.data) {
    savingsByMember[r.target_member_id] =
      (savingsByMember[r.target_member_id] || 0) + Number(r.delta)
  }
  const activeLoanByMember = new Set(
    loans.filter((l) => l.status === 'active').map((l) => l.member_id),
  )

  // Grid: one row per active member (admin included, Decision #1).
  const gridRows = profiles.map((p) => {
    const fee = feeByMember[p.id] || null
    const installment = currentInstByMember[p.id] || null
    const statuses = [fee?.computed_status, installment?.computed_status].filter(Boolean)
    let overall = 'pending'
    if (statuses.includes('overdue')) overall = 'overdue'
    else if (statuses.length && statuses.every((s) => s === 'paid')) overall = 'paid'
    return {
      id: p.id,
      name: p.full_name,
      role: p.role,
      fee,
      installment,
      overall,
      savings: savingsByMember[p.id] || 0,
      paidFees: paidFeesByMember[p.id] || 0,
      hasActiveLoan: activeLoanByMember.has(p.id),
    }
  })

  const feesThisPeriod = fees.filter((f) => f.period === currentPeriod)
  const pendingSubs = subs.filter((s) => s.status === 'pending')
  const pendingLoansArr = loans.filter((l) => l.status === 'pending')

  // Required approvals = min(2, active admin count). With one admin it falls back
  // to single-admin approval; once a second admin is promoted, every approval needs
  // two signatures.
  const adminCount = profiles.filter((p) => p.role === 'admin').length
  const requiredApprovals = Math.min(2, Math.max(1, adminCount))

  // Group approvals by their target id, ordered oldest-first (the first approver's
  // amount/proof wins on finalization, mirroring the SQL).
  const subApprovalsBy = {}
  for (const a of subApprovalsRes.data) {
    ;(subApprovalsBy[a.submission_id] ||= []).push(a)
  }
  const loanApprovalsBy = {}
  for (const a of loanApprovalsRes.data) {
    ;(loanApprovalsBy[a.loan_id] ||= []).push(a)
  }

  const stats = {
    pool,
    outstandingLoans,
    totalAssets,
    feesPaid: feesThisPeriod.filter((f) => f.status === 'paid').length,
    feesTotal: feesThisPeriod.length || profiles.length,
    activeLoans: loans.filter((l) => l.status === 'active').length,
    pendingReviews: pendingSubs.length + pendingLoansArr.length,
    adminCount,
    requiredApprovals,
  }

  // Has the member ever held a loan that proceeded past 'pending'? Drives the
  // queue's first-time-borrower priority (members without prior loans appear first).
  const everBorrowed = new Set(
    loans.filter((l) => l.status === 'active' || l.status === 'closed').map((l) => l.member_id),
  )

  const pendingLoans = pendingLoansArr
    .map((l) => {
      const savings = savingsByMember[l.member_id] || 0
      // contribution now equals savings (paid fees are folded in above).
      const contribution = savings
      const approvals = loanApprovalsBy[l.id] || []
      const approverNames = approvals.map((a) => profileName[a.admin_id] || 'unknown')
      const iApproved = !!(currentAdminId && approvals.some((a) => a.admin_id === currentAdminId))
      const isSelf = currentAdminId === l.member_id
      return {
        ...l,
        memberName: profileName[l.member_id] || 'Unknown',
        contribution,
        contributionCeiling: contributionCeiling(contribution),
        poolCeiling: poolCap,
        maxEligible: maxLoan(contribution, pool),
        hasPriorLoan: everBorrowed.has(l.member_id),
        approvalsCount: approvals.length,
        requiredApprovals,
        approverNames,
        iApproved,
        isSelf,
        canApprove: !iApproved && !isSelf,
        firstProofUrl: approvals[0]?.proof_url ?? null,
      }
    })
    // First-time borrowers first; within each group, oldest request wins.
    .sort((a, b) => {
      if (a.hasPriorLoan !== b.hasPriorLoan) return a.hasPriorLoan ? 1 : -1
      return new Date(a.requested_at).getTime() - new Date(b.requested_at).getTime()
    })

  const feeById = Object.fromEntries(fees.map((f) => [f.id, f]))
  const instById = Object.fromEntries(installments.map((i) => [i.id, i]))
  const pendingPayments = pendingSubs.map((s) => {
    let suggested = Number(s.amount_claimed)
    let penalty = 0
    // Identifying context the admin needs to know *what* is being paid:
    //   - monthly_fee: the period (e.g., May 2026)
    //   - loan_installment: which installment (#1/2/3) and its due date
    let period = null
    let installmentNumber = null
    let dueDate = null
    if (s.submission_type === 'monthly_fee' && feeById[s.related_id]) {
      const fee = feeById[s.related_id]
      suggested = Number(fee.total_with_penalty)
      penalty = Number(fee.penalty_due)
      period = fee.period
    } else if (s.submission_type === 'loan_installment' && instById[s.related_id]) {
      const inst = instById[s.related_id]
      suggested = Number(inst.total_with_penalty)
      penalty = Number(inst.penalty_due)
      installmentNumber = inst.installment_number
      dueDate = inst.due_date
    }
    const approvals = subApprovalsBy[s.id] || []
    const approverNames = approvals.map((a) => profileName[a.admin_id] || 'unknown')
    const iApproved = !!(currentAdminId && approvals.some((a) => a.admin_id === currentAdminId))
    const isSelf = currentAdminId === s.member_id
    return {
      ...s,
      memberName: profileName[s.member_id] || 'Unknown',
      suggested,
      penalty,
      period,
      installmentNumber,
      dueDate,
      approvalsCount: approvals.length,
      requiredApprovals,
      approverNames,
      iApproved,
      isSelf,
      canApprove: !iApproved && !isSelf,
      firstAmount: approvals[0] ? Number(approvals[0].amount_received) : null,
    }
  })

  // Pending member-deletion requests with approval state.
  const deletionApprovalsBy = {}
  for (const a of deletionApprovalsRes.data) {
    ;(deletionApprovalsBy[a.request_id] ||= []).push(a)
  }
  const pendingDeletions = deletionRequestsRes.data.map((r) => {
    const approvals = deletionApprovalsBy[r.id] || []
    const approverNames = approvals.map((a) => profileName[a.admin_id] || 'unknown')
    const iApproved = !!(currentAdminId && approvals.some((a) => a.admin_id === currentAdminId))
    const isSelf = currentAdminId === r.target_member_id
    const targetSavings = savingsByMember[r.target_member_id] || 0
    const targetPaidFees = paidFeesByMember[r.target_member_id] || 0
    return {
      ...r,
      requesterName: r.requested_by ? profileName[r.requested_by] || 'unknown' : 'unknown',
      approvalsCount: approvals.length,
      requiredApprovals,
      approverNames,
      iApproved,
      isSelf,
      canApprove: !iApproved && !isSelf,
      targetSavings,
      targetPaidFees,
    }
  })

  // Pending savings-edit requests (migration 013). Requester does NOT auto-vote
  // and target cannot approve, so canApprove gates them out.
  const savingsEditApprovalsBy = {}
  for (const a of savingsEditApprovalsRes.data) {
    ;(savingsEditApprovalsBy[a.adjustment_id] ||= []).push(a)
  }
  const pendingSavingsEdits = savingsEditsRes.data.map((r) => {
    const approvals = savingsEditApprovalsBy[r.id] || []
    const approverNames = approvals.map((a) => profileName[a.admin_id] || 'unknown')
    const iApproved = !!(currentAdminId && approvals.some((a) => a.admin_id === currentAdminId))
    const isRequester = currentAdminId === r.requested_by
    const isTarget = currentAdminId === r.target_member_id
    // Required approvals = min(2, count of admins OTHER than the requester).
    const otherAdmins = profiles.filter((p) => p.role === 'admin' && p.id !== r.requested_by).length
    const reqRequired = Math.min(2, otherAdmins)
    return {
      ...r,
      requesterName: r.requested_by ? profileName[r.requested_by] || 'unknown' : 'unknown',
      targetName: profileName[r.target_member_id] || 'Unknown',
      currentSavings: savingsByMember[r.target_member_id] || 0,
      approvalsCount: approvals.length,
      requiredApprovals: reqRequired,
      approverNames,
      iApproved,
      isRequester,
      isTarget,
      canApprove: !iApproved && !isRequester && !isTarget,
    }
  })

  // Pending pool-edit requests (migration 015). Same 2-of-N pattern as savings
  // edits: requester does NOT auto-vote and can't approve their own request.
  const poolEditApprovalsBy = {}
  for (const a of poolEditApprovalsRes.data) {
    ;(poolEditApprovalsBy[a.adjustment_id] ||= []).push(a)
  }
  const pendingPoolEdits = poolEditsRes.data.map((r) => {
    const approvals = poolEditApprovalsBy[r.id] || []
    const approverNames = approvals.map((a) => profileName[a.admin_id] || 'unknown')
    const iApproved = !!(currentAdminId && approvals.some((a) => a.admin_id === currentAdminId))
    const isRequester = currentAdminId === r.requested_by
    const otherAdmins = profiles.filter((p) => p.role === 'admin' && p.id !== r.requested_by).length
    const reqRequired = Math.min(2, otherAdmins)
    return {
      ...r,
      requesterName: r.requested_by ? profileName[r.requested_by] || 'unknown' : 'unknown',
      approvalsCount: approvals.length,
      requiredApprovals: reqRequired,
      approverNames,
      iApproved,
      isRequester,
      canApprove: !iApproved && !isRequester,
    }
  })

  // Pending admin role-change requests. Same pattern: requester does NOT
  // auto-vote, target can't approve (handled in DB), other admins must approve.
  const roleChangeApprovalsBy = {}
  for (const a of roleChangeApprovalsRes.data) {
    ;(roleChangeApprovalsBy[a.request_id] ||= []).push(a)
  }
  const pendingRoleChanges = roleChangeRequestsRes.data.map((r) => {
    const approvals = roleChangeApprovalsBy[r.id] || []
    const approverNames = approvals.map((a) => profileName[a.admin_id] || 'unknown')
    const iApproved = !!(currentAdminId && approvals.some((a) => a.admin_id === currentAdminId))
    const isRequester = currentAdminId === r.requested_by
    const isTarget = currentAdminId === r.target_member_id
    const otherAdmins = profiles.filter((p) => p.role === 'admin' && p.id !== r.requested_by).length
    const reqRequired = Math.min(2, otherAdmins)
    return {
      ...r,
      requesterName: r.requested_by ? profileName[r.requested_by] || 'unknown' : 'unknown',
      targetName: profileName[r.target_member_id] || 'Unknown',
      approvalsCount: approvals.length,
      requiredApprovals: reqRequired,
      approverNames,
      iApproved,
      isRequester,
      isTarget,
      canApprove: !iApproved && !isRequester && !isTarget,
    }
  })

  return {
    stats,
    gridRows,
    pendingLoans,
    pendingPayments,
    pendingDeletions,
    pendingSavingsEdits,
    pendingPoolEdits,
    pendingRoleChanges,
    currentMonthKey,
  }
}

// Admin: open a request to adjust the group pool by a positive or negative
// delta. Total assets (= pool + outstanding loans) shifts by the same amount.
// The requester's vote does NOT auto-count — two OTHER admins must approve.
export async function requestPoolEdit(supabase, delta, reason) {
  const { data, error } = await supabase.rpc('request_pool_edit', {
    p_delta: delta,
    p_reason: reason,
  })
  if (error) throw error
  return data
}

export async function approvePoolEdit(supabase, requestId) {
  const { error } = await supabase.rpc('approve_pool_edit', { p_request_id: requestId })
  if (error) throw error
}

export async function cancelPoolEdit(supabase, requestId) {
  const { error } = await supabase.rpc('cancel_pool_edit', { p_request_id: requestId })
  if (error) throw error
}

// Admin: open a request to promote a member to admin or revoke an admin's role.
// Requester does NOT auto-vote — two OTHER admins must approve. The DB blocks
// promoting an existing admin, demoting a non-admin, and demoting the last admin.
export async function requestRoleChange(supabase, targetMemberId, changeType, reason) {
  const { data, error } = await supabase.rpc('request_role_change', {
    p_target_member_id: targetMemberId,
    p_change_type: changeType,
    p_reason: reason,
  })
  if (error) throw error
  return data
}

export async function approveRoleChange(supabase, requestId) {
  const { error } = await supabase.rpc('approve_role_change', { p_request_id: requestId })
  if (error) throw error
}

export async function cancelRoleChange(supabase, requestId) {
  const { error } = await supabase.rpc('cancel_role_change', { p_request_id: requestId })
  if (error) throw error
}

// Admin: open a request to adjust a member's savings by a positive or negative
// delta. Target can be any non-admin member OR the caller themselves; never
// another admin. The requester's vote does NOT auto-count toward the threshold
// — two OTHER admins must approve before the adjustment applies.
export async function requestSavingsEdit(supabase, targetMemberId, delta, reason) {
  const { data, error } = await supabase.rpc('request_savings_edit', {
    p_target_member_id: targetMemberId,
    p_delta: delta,
    p_reason: reason,
  })
  if (error) throw error
  return data
}

export async function approveSavingsEdit(supabase, requestId) {
  const { error } = await supabase.rpc('approve_savings_edit', { p_request_id: requestId })
  if (error) throw error
}

export async function cancelSavingsEdit(supabase, requestId) {
  const { error } = await supabase.rpc('cancel_savings_edit', { p_request_id: requestId })
  if (error) throw error
}

// Admin: open a deletion request for another member. Returns the request id.
// Server-side blocks self-targeting, deletion of the last admin, and overlapping
// pending requests for the same target.
export async function requestMemberDeletion(supabase, targetMemberId, reason) {
  const { data, error } = await supabase.rpc('request_member_deletion', {
    p_target_member_id: targetMemberId,
    p_reason: reason || null,
  })
  if (error) throw error
  return data
}

// Admin: vote on an existing pending deletion request. When the 2-of-N threshold
// is reached the RPC executes the deletion in the same transaction.
export async function approveMemberDeletion(supabase, requestId) {
  const { error } = await supabase.rpc('approve_member_deletion', { p_request_id: requestId })
  if (error) throw error
}

// Admin: cancel a pending deletion request.
export async function cancelMemberDeletion(supabase, requestId) {
  const { error } = await supabase.rpc('cancel_member_deletion', { p_request_id: requestId })
  if (error) throw error
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
