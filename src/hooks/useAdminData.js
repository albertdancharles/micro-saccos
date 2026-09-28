// Admin dashboard data (build plan §3 item 25, §9). Loads the grid, stats, and the
// approval queues in one pass and exposes refresh() for after an approve/reject.
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useAuth } from './useAuth'
import { useCoalesced } from './useCoalesced'
import { getAdminData } from '../lib/admin'
import { SETTING_DEFAULTS } from '../lib/settings'

const EMPTY = {
  stats: {
    pool: 0,
    outstandingLoans: 0,
    totalAssets: 0,
    feesPaid: 0,
    feesTotal: 0,
    activeLoans: 0,
    pendingReviews: 0,
    adminCount: 0,
    requiredApprovals: 1,
  },
  gridRows: [],
  pendingLoans: [],
  pendingPayments: [],
  pendingDeletions: [],
  pendingSavingsEdits: [],
  pendingPoolEdits: [],
  pendingRoleChanges: [],
  pendingSettingChanges: [],
  pendingLoanActions: [],
  pendingWithdrawals: [],
  pendingMembers: [],
  formerMembers: [],
  activeLoans: [],
  reconciliation: null,
  messaging: null,
  settings: SETTING_DEFAULTS,
  settingRows: [],
  currentMonthKey: '',
}

export function useAdminData() {
  const { user } = useAuth()
  const currentAdminId = user?.id ?? null
  const [data, setData] = useState(EMPTY)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const load = useCallback(async () => {
    if (!supabase) return
    try {
      setData(await getAdminData(supabase, currentAdminId))
      setError(null)
    } catch (err) {
      console.error('useAdminData load failed', err)
      setError(err?.message || 'Could not load the admin dashboard.')
    } finally {
      setLoading(false)
    }
  }, [currentAdminId])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  // A batch write lands as dozens of events at once (the fee sheet posts the whole
  // group in one transaction), so the subscriptions below fire a coalesced reload
  // rather than one full reload per row.
  const reload = useCoalesced(load)

  // Realtime: refetch whenever a submission or loan changes (any admin's queue +
  // any member's status updates within a second of each other).
  useEffect(() => {
    if (!supabase) return
    const channel = supabase
      .channel('admin-data')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'payment_submissions' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'loans' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'monthly_fees' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'loan_installments' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'submission_approvals' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'loan_approvals' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'deletion_requests' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'deletion_approvals' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'savings_adjustments' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'savings_adjustment_approvals' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'pool_adjustments' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'pool_adjustment_approvals' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'role_change_requests' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'role_change_approvals' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'setting_changes' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'setting_change_approvals' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'group_settings' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'loan_actions' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'loan_action_approvals' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'withdrawal_requests' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'withdrawal_approvals' }, reload)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'profiles' }, reload)
      .subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
  }, [reload])

  return { ...data, loading, error, refresh: load }
}
