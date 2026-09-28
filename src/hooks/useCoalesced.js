// Collapse a burst of realtime events into one refetch.
//
// The admin dashboard subscribes to 22 tables, and every event calls load(),
// which is ~29 queries. That is fine for one approval and badly wrong for the
// work this app actually does: posting the monthly fee sheet for a fifteen-member
// group writes fifteen payment_submissions, fifteen submission_approvals and
// fifteen monthly_fees updates in a single transaction. Those arrive as ~45
// separate events, each starting a full reload of the dashboard — roughly 1,300
// queries for one button press, on a phone, over 3G, with the later responses
// racing the earlier ones to set state.
//
// A short trailing window folds the burst into one load. It is deliberately
// short: this is a coalescing window, not a throttle, and a single approval by
// another admin should still land in well under a blink.
import { useCallback, useEffect, useRef } from 'react'

export function useCoalesced(fn, delay = 250) {
  const fnRef = useRef(fn)
  const timerRef = useRef(null)

  // Keep the latest fn without re-arming the timer, so a re-render mid-burst
  // does not drop a pending refetch.
  useEffect(() => {
    fnRef.current = fn
  }, [fn])

  useEffect(
    () => () => {
      if (timerRef.current) clearTimeout(timerRef.current)
    },
    [],
  )

  return useCallback(() => {
    if (timerRef.current) clearTimeout(timerRef.current)
    timerRef.current = setTimeout(() => {
      timerRef.current = null
      fnRef.current?.()
    }, delay)
  }, [delay])
}
