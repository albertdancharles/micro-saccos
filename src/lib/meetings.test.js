import { describe, it, expect } from 'vitest'
import { lastMeetingOnOrBefore, recordSocialContributionForAll } from './meetings'

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

// Everyone pays the same welfare contribution at the monthly meeting, so the form
// can post one for the whole group at once. There is no bulk RPC behind it, which
// makes a half-finished run possible — and a half-finished run the admin cannot
// see is the dangerous one, because re-running it pays the earlier members twice.

describe('recordSocialContributionForAll', () => {
  // A stand-in for supabase.rpc that records what it was asked to do, and fails
  // for whichever member ids are named.
  function fakeSupabase(failFor = []) {
    const calls = []
    return {
      calls,
      rpc(name, args) {
        calls.push({ name, args })
        if (failFor.includes(args.p_member_id)) {
          return Promise.resolve({ data: null, error: new Error('Not authorized') })
        }
        return Promise.resolve({ data: `entry-${args.p_member_id}`, error: null })
      },
    }
  }

  it('posts one contribution per member, with the same amount and reason', async () => {
    const db = fakeSupabase()

    const { saved, failed } = await recordSocialContributionForAll(
      db,
      ['a', 'b', 'c'],
      5000,
      'monthly welfare contribution',
    )

    expect(saved).toEqual(['a', 'b', 'c'])
    expect(failed).toEqual([])
    expect(db.calls).toHaveLength(3)
    expect(db.calls.map((c) => c.args.p_member_id)).toEqual(['a', 'b', 'c'])
    expect(db.calls.every((c) => c.name === 'record_social_contribution')).toBe(true)
    expect(db.calls.every((c) => c.args.p_amount === 5000)).toBe(true)
    expect(db.calls.every((c) => c.args.p_reason === 'monthly welfare contribution')).toBe(true)
  })

  // The whole point of collecting failures instead of throwing: one member who
  // cannot be recorded must not cost the other fourteen their contribution.
  it('keeps going past a member who fails, and names the ones that did not land', async () => {
    const db = fakeSupabase(['b'])

    const { saved, failed } = await recordSocialContributionForAll(db, ['a', 'b', 'c'], 5000, 'dues')

    expect(saved).toEqual(['a', 'c'])
    expect(failed).toEqual([{ memberId: 'b', message: 'Not authorized' }])
    expect(db.calls).toHaveLength(3)
  })

  it('reports every member when nothing could be saved', async () => {
    const db = fakeSupabase(['a', 'b'])

    const { saved, failed } = await recordSocialContributionForAll(db, ['a', 'b'], 5000, 'dues')

    expect(saved).toEqual([])
    expect(failed.map((f) => f.memberId)).toEqual(['a', 'b'])
  })

  it('does nothing at all for an empty group', async () => {
    const db = fakeSupabase()

    const { saved, failed } = await recordSocialContributionForAll(db, [], 5000, 'dues')

    expect(saved).toEqual([])
    expect(failed).toEqual([])
    expect(db.calls).toEqual([])
  })
})
