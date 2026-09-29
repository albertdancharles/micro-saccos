import { describe, it, expect } from 'vitest'
import { lastMeetingOnOrBefore } from './meetings'

// The group meets on the last Saturday of every month. These dates are the ones
// migration 043's meeting_day() must also produce — if the two ever disagree, a
// loan's due date stops landing on a meeting.

describe('lastMeetingOnOrBefore', () => {
  it('returns this month\'s meeting once it has happened', () => {
    // 2026-09-26 is the last Saturday of September; the 29th is after it.
    expect(lastMeetingOnOrBefore(new Date(2026, 8, 29))).toBe('2026-09-26')
  })

  it('returns the meeting itself on the day it is held', () => {
    expect(lastMeetingOnOrBefore(new Date(2026, 8, 26))).toBe('2026-09-26')
  })

  it('reaches back to last month when this month has not met yet', () => {
    // record_meeting rejects a future date, so on 2026-10-05 the meeting to
    // record is September's — October's is still 26 days away.
    expect(lastMeetingOnOrBefore(new Date(2026, 9, 5))).toBe('2026-09-26')
  })

  it('crosses the year boundary', () => {
    expect(lastMeetingOnOrBefore(new Date(2027, 0, 4))).toBe('2026-12-26')
  })

  it('handles a month that ends on a Saturday', () => {
    // 2026-10-31 is itself a Saturday, so it is the meeting day.
    expect(lastMeetingOnOrBefore(new Date(2026, 9, 31))).toBe('2026-10-31')
  })

  it('handles February in a leap year', () => {
    // 2028-02-29 is a Tuesday; the last Saturday is the 26th.
    expect(lastMeetingOnOrBefore(new Date(2028, 1, 29))).toBe('2028-02-26')
  })

  it('always lands on a Saturday, for every month across four years', () => {
    for (let y = 2026; y <= 2029; y++) {
      for (let m = 0; m < 12; m++) {
        // The last day of the month is always on or after that month's meeting.
        const endOfMonth = new Date(y, m + 1, 0)
        const iso = lastMeetingOnOrBefore(endOfMonth)
        const [yy, mm, dd] = iso.split('-').map(Number)
        expect(new Date(yy, mm - 1, dd).getDay()).toBe(6)
        // ...and it is that same month's meeting, not an earlier one.
        expect(mm - 1).toBe(m)
      }
    }
  })
})
