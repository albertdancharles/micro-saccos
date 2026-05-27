// Admin dashboard data (build plan §3 item 25, §9). Loads the grid, stats, and the
// approval queues in one pass and exposes refresh() for after an approve/reject.
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { getAdminData } from '../lib/admin'

const EMPTY = {
  stats: { pool: 0, feesPaid: 0, feesTotal: 0, activeLoans: 0, pendingReviews: 0 },
  gridRows: [],
  pendingLoans: [],
  pendingPayments: [],
  currentMonthKey: '',
}

export function useAdminData() {
  const [data, setData] = useState(EMPTY)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const load = useCallback(async () => {
    if (!supabase) return
    try {
      setData(await getAdminData(supabase))
      setError(null)
    } catch (err) {
      console.error('useAdminData load failed', err)
      setError(err?.message || 'Could not load the admin dashboard.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  return { ...data, loading, error, refresh: load }
}
