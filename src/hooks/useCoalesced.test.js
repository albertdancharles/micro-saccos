// A burst of realtime events must become exactly one refetch — and must never
// become zero. Posting the monthly fee sheet writes three rows per member in one
// transaction, so a fifteen-member group emits ~45 events; each used to start a
// full reload of a 29-query dashboard.
import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useCoalesced } from './useCoalesced'

beforeEach(() => vi.useFakeTimers())
afterEach(() => vi.useRealTimers())

describe('useCoalesced', () => {
  it('collapses a burst into a single call', () => {
    const load = vi.fn()
    const { result } = renderHook(() => useCoalesced(load, 250))

    act(() => {
      for (let i = 0; i < 45; i++) result.current()
    })
    expect(load).not.toHaveBeenCalled()

    act(() => vi.advanceTimersByTime(250))
    expect(load).toHaveBeenCalledTimes(1)
  })

  it('still fires for a single event', () => {
    const load = vi.fn()
    const { result } = renderHook(() => useCoalesced(load, 250))

    act(() => result.current())
    act(() => vi.advanceTimersByTime(250))

    expect(load).toHaveBeenCalledTimes(1)
  })

  it('fires again for a later, separate burst', () => {
    const load = vi.fn()
    const { result } = renderHook(() => useCoalesced(load, 250))

    act(() => result.current())
    act(() => vi.advanceTimersByTime(250))
    act(() => result.current())
    act(() => vi.advanceTimersByTime(250))

    expect(load).toHaveBeenCalledTimes(2)
  })

  // The hook holds fn in a ref so a re-render mid-burst does not re-arm the timer
  // and lose the pending refetch — but it must then call the CURRENT fn, or the
  // dashboard reloads with a stale admin id after a profile change.
  it('calls the latest callback, not the one captured when the burst began', () => {
    const first = vi.fn()
    const second = vi.fn()
    const { result, rerender } = renderHook(({ fn }) => useCoalesced(fn, 250), {
      initialProps: { fn: first },
    })

    act(() => result.current())
    rerender({ fn: second })
    act(() => vi.advanceTimersByTime(250))

    expect(first).not.toHaveBeenCalled()
    expect(second).toHaveBeenCalledTimes(1)
  })

  it('does not fire after unmount', () => {
    const load = vi.fn()
    const { result, unmount } = renderHook(() => useCoalesced(load, 250))

    act(() => result.current())
    unmount()
    act(() => vi.advanceTimersByTime(250))

    expect(load).not.toHaveBeenCalled()
  })
})
