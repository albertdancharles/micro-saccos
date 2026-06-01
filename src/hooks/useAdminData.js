// Admin dashboard data (build plan §3 item 25, §9). Loads the grid, stats, and the
// approval queues in one pass and exposes refresh() for after an approve/reject.
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useAuth } from './useAuth'
import { getAdminData } from '../lib/admin'

const EMPTY = {
  stats: {
    pool: 0,
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

  // Realtime: refetch whenever a submission or loan changes (any admin's queue +
  // any member's status updates within a second of each other).
  useEffect(() => {
    if (!supabase) return
    const channel = supabase
      .channel('admin-data')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'payment_submissions' }, load)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'loans' }, load)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'monthly_fees' }, load)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'loan_installments' }, load)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'submission_approvals' }, load)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'loan_approvals' }, load)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'deletion_requests' }, load)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'deletion_approvals' }, load)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'profiles' }, load)
      .subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
  }, [load])

  return { ...data, loading, error, refresh: load }
}
