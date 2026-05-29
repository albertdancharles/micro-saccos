// Notifications hook (Phase 4). Fetches the recipient's recent notifications,
// subscribes to realtime so new ones appear without refresh, and exposes a
// markAllRead action.
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useAuth } from './useAuth'

const LIMIT = 20

export function useNotifications() {
  const { user } = useAuth()
  const userId = user?.id ?? null
  const [items, setItems] = useState([])
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    if (!supabase || !userId) return
    const { data, error } = await supabase
      .from('notifications')
      .select('*')
      .eq('recipient_id', userId)
      .order('created_at', { ascending: false })
      .limit(LIMIT)
    if (error) {
      console.error('Failed to load notifications', error)
    } else {
      setItems(data || [])
    }
    setLoading(false)
  }, [userId])

  useEffect(() => {
    // load() sets state only after an await; false positive on the rule.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  // Realtime: refetch when this user's notifications change (new inserts,
  // mark-read updates).
  useEffect(() => {
    if (!supabase || !userId) return
    const channel = supabase
      .channel(`notifications-${userId}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'notifications', filter: `recipient_id=eq.${userId}` },
        load,
      )
      .subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
  }, [userId, load])

  const unreadCount = items.reduce((n, i) => (i.read_at ? n : n + 1), 0)

  const markAllRead = useCallback(async () => {
    if (!supabase || !userId) return
    const unreadIds = items.filter((i) => !i.read_at).map((i) => i.id)
    if (!unreadIds.length) return
    await supabase
      .from('notifications')
      .update({ read_at: new Date().toISOString() })
      .in('id', unreadIds)
    // realtime will reload, but trigger one immediately so the badge updates
    // without waiting for the subscription roundtrip.
    load()
  }, [items, userId, load])

  return { items, unreadCount, loading, markAllRead, refresh: load }
}
