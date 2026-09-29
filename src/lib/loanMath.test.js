import { describe, it, expect } from 'vitest'
import {
  assetsCeiling,
  contributionCeiling,
  maxLoan,
  monthlyInterest,
  penaltyDue,
} from './loanMath'

describe('assetsCeiling', () => {
  it('is 25% of total group assets, floored to whole TZS', () => {
    expect(assetsCeiling(1000000)).toBe(250000)
    expect(assetsCeiling(10001)).toBe(2500) // floor(2500.25)
    expect(assetsCeiling(0)).toBe(0)
  })
})

describe('contributionCeiling', () => {
  it('is 5x the member contribution, floored to whole TZS', () => {
    expect(contributionCeiling(10000)).toBe(50000)
    expect(contributionCeiling(0)).toBe(0)
  })
})

describe('maxLoan', () => {
  it('is the lower of 5x contribution and 25% of group assets', () => {
    // contribution binds: 5*5000=25,000 < 25% of 1,000,000=250,000
    expect(maxLoan(5000, 1000000)).toBe(25000)
    // assets bind: 25% of 200,000=50,000 < 5*50,000=250,000
    expect(maxLoan(50000, 200000)).toBe(50000)
    expect(maxLoan(0, 1000000)).toBe(0) // no contribution → no loan
    expect(maxLoan(100000, 0)).toBe(0)  // a group worth nothing → no loan
  })

  it('does not shrink as the group lends (045)', () => {
    // A group worth 4,000,000 lends 3,000,000 of it. The pool is down to
    // 1,000,000 but the group is worth the same, so the ceiling holds at
    // 25% of 4,000,000 — not at 25% of what is left in the pool.
    const assets = 4000000
    expect(maxLoan(1000000, assets)).toBe(1000000)
    // The old rule would have given 25% of the remaining 1,000,000 pool.
    expect(maxLoan(1000000, 1000000)).toBe(250000)
  })
})

describe('monthlyInterest', () => {
  it('is 5% of principal, rounded to whole TZS', () => {
    expect(monthlyInterest(100000)).toBe(5000)
    expect(monthlyInterest(33333)).toBe(1667) // round(1666.65)
  })
})

describe('penaltyDue', () => {
  it('is zero when not overdue', () => {
    expect(penaltyDue(10000, 0)).toBe(0)
  })

  it('is 5% x base x months overdue, whole TZS', () => {
    expect(penaltyDue(10000, 1)).toBe(500)
    expect(penaltyDue(10000, 3)).toBe(1500)
  })
})
