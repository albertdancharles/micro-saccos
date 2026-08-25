// Member summary (build plan §3 item 15, §9). Aggregates everything the member
// dashboard renders: group pool, my savings, my current loan + schedule, my fees,
// and the derived "amount due" (incl. live penalties from the money views).
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useAuth } from './useAuth'
import { getApprovedSavings } from '../lib/savings'
import { getCurrentLoan, getInstallments } from '../lib/loans'
import { getMyFees } from '../lib/fees'

// 'YYYY-MM' for month comparison (period and due_date are DB date strings, already EAT).
const monthKey = (dateStr) => (dateStr ? String(dateStr).slice(0, 7) : '')

const EMPTY = {
  pool: 0,
  outstandingLoans: 0,
  totalAssets: 0,
  savings: 0,
  paidFees: 0,
  contribution: 0,
  loan: null,
  fees: [],
  installments: [],
  currentMonthKey: '',
  amountDue: 0,
  penaltyDue: 0,
}

// `overrideMemberId` lets an admin view another member's dashboard. When null,
// the hook loads data for the currently signed-in user. RLS allows admins to
// read every member's rows, so the same queries work in both contexts.
export function useMemberSummary(overrideMemberId = null) {
  const { user } = useAuth()
  const memberId = overrideMemberId ?? user?.id ?? null
  const [data, setData] = useState(EMPTY)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const load = useCallback(async () => {
    if (!supabase || !memberId) return
    try {
      const [savings, loan, fees, assetsRes] = await Promise.all([
        getApprovedSavings(supabase, memberId),
        getCurrentLoan(supabase, memberId),
        getMyFees(supabase, memberId),
        supabase
          .from('v_group_assets')
          .select('pool_balance_tzs, outstanding_loans_tzs, total_assets_tzs')
          .single(),
      ])
      if (assetsRes.error) throw assetsRes.error

      const installments = loan?.status === 'active' ? await getInstallments(supabase, loan.id) : []

      // Current month = the latest fee period (fees are generated monthly).
      const currentMonthKey = fees.length ? monthKey(fees[0].period) : ''

      // Fee money actually banked, broken out for the Profile contributions
      // breakdown. Uses amount_paid across every row so a part-settled fee still
      // counts (migration 021). getApprovedSavings already folds these into the
      // savings total, so the contribution driving the loan ceiling equals savings.
      const paidFees = fees.reduce((s, f) => s + Number(f.amount_paid ?? 0), 0)
      const contribution = savings

      // Amount due now = unpaid fees + installments that are overdue or due this
      // month. Cancelled installments are historical, never an obligation.
      const feesDue = fees.filter((f) => f.computed_status !== 'paid')
      const instDue = installments.filter(
        (i) =>
          i.computed_status !== 'paid' &&
          i.computed_status !== 'cancelled' &&
          (i.computed_status === 'overdue' || monthKey(i.due_date) === currentMonthKey),
      )
      const due = [...feesDue, ...instDue]
      const amountDue = due.reduce((s, r) => s + Number(r.total_with_penalty), 0)
      const penaltyDue = due.reduce((s, r) => s + Number(r.penalty_due), 0)

      setData({
        pool: Number(assetsRes.data?.pool_balance_tzs ?? 0),
        outstandingLoans: Number(assetsRes.data?.outstanding_loans_tzs ?? 0),
        totalAssets: Number(assetsRes.data?.total_assets_tzs ?? 0),
        savings,
        paidFees,
        contribution,
        loan,
        fees,
        installments,
        currentMonthKey,
        amountDue,
        penaltyDue,
      })
      setError(null)
    } catch (err) {
      console.error('useMemberSummary load failed', err)
      setError(err?.message || 'Could not load your dashboard.')
    } finally {
      setLoading(false)
    }
  }, [memberId])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — the rule
    // can't see across the async boundary, so this disable is a false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  // Realtime: when this member's own submissions, fees, loans, or installments
  // change (e.g. admin approves), refetch the summary. Filtered so we only
  // listen for rows that touch this member.
  useEffect(() => {
    if (!supabase || !memberId) return
    const memberFilter = `member_id=eq.${memberId}`
    const channel = supabase
      .channel(`member-summary-${memberId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'payment_submissions', filter: memberFilter }, load)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'monthly_fees', filter: memberFilter }, load)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'loans', filter: memberFilter }, load)
      // loan_installments has no member_id (only loan_id), so refetch on any change;
      // the queries are cheap and only an active borrower will see frequent updates.
      .on('postgres_changes', { event: '*', schema: 'public', table: 'loan_installments' }, load)
      .subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
  }, [memberId, load])

  return { ...data, loading, error, refresh: load }
}
