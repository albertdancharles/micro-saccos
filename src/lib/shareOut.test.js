import { describe, it, expect } from 'vitest'
import { allocateShares, shareOutTotals } from './shareOut'

const members = [
  { member_id: 'a', basis: 1200000, closing_capital: 100000 },
  { member_id: 'b', basis: 600000, closing_capital: 50000 },
  { member_id: 'c', basis: 200000, closing_capital: 20000 },
]

describe('allocateShares', () => {
  it('splits the pot in proportion to the time-weighted basis', () => {
    const out = allocateShares(members, 100000)
    // basis 1.2M : 600k : 200k = 60% : 30% : 10%
    expect(out.map((r) => r.earnings)).toEqual([60000, 30000, 10000])
  })

  it('distributes every shilling — shares always sum to the pot', () => {
    // 100,001 over three uneven shares forces remainders.
    const out = allocateShares(members, 100001)
    expect(shareOutTotals(out).earnings).toBe(100001)
  })

  it('never leaves a stray shilling, across many awkward pots', () => {
    for (const pot of [1, 2, 7, 999, 12345, 88888]) {
      const out = allocateShares(members, pot)
      expect(shareOutTotals(out).earnings).toBe(pot)
    }
  })

  it('gives a late joiner a small share, not an equal one', () => {
    // Same closing capital, but `late` was only in for the final month.
    const rows = [
      { member_id: 'early', basis: 1200000, closing_capital: 100000 },
      { member_id: 'late', basis: 100000, closing_capital: 100000 },
    ]
    const out = allocateShares(rows, 130000)
    expect(out[0].earnings).toBeGreaterThan(out[1].earnings * 10)
    expect(shareOutTotals(out).earnings).toBe(130000)
  })

  it('pays no earnings in a loss year rather than billing members', () => {
    const out = allocateShares(members, -50000)
    expect(out.every((r) => r.earnings === 0)).toBe(true)
    expect(shareOutTotals(out).earnings).toBe(0)
  })

  it('returns capital only in full_shareout mode', () => {
    const earningsOnly = allocateShares(members, 100000, 'earnings_only')
    expect(shareOutTotals(earningsOnly).capital).toBe(0)
    expect(shareOutTotals(earningsOnly).total).toBe(100000)

    const full = allocateShares(members, 100000, 'full_shareout')
    expect(shareOutTotals(full).capital).toBe(170000)
    expect(shareOutTotals(full).total).toBe(270000)
  })

  it('handles a cycle where nobody contributed anything', () => {
    const out = allocateShares([{ member_id: 'a', basis: 0, closing_capital: 0 }], 5000)
    expect(out[0].earnings).toBe(0)
    expect(out[0].ratio).toBe(0)
  })

  it('breaks remainder ties by member id so SQL and JS agree', () => {
    // Identical bases → identical fractional parts; 1 leftover shilling must go to
    // the lowest member_id, exactly as the SQL's ORDER BY … , member_id does.
    const tied = [
      { member_id: 'b', basis: 100, closing_capital: 0 },
      { member_id: 'a', basis: 100, closing_capital: 0 },
    ]
    const out = allocateShares(tied, 3)
    expect(out.find((r) => r.member_id === 'a').earnings).toBe(2)
    expect(out.find((r) => r.member_id === 'b').earnings).toBe(1)
  })
})
