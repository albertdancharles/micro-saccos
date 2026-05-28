import { describe, it, expect } from 'vitest'
import {
  poolCeiling,
  contributionCeiling,
  maxLoan,
  monthlyInterest,
  penaltyDue,
} from './loanMath'

describe('poolCeiling', () => {
  it('is 25% of the pool, floored to whole TZS', () => {
    expect(poolCeiling(1000000)).toBe(250000)
    expect(poolCeiling(10001)).toBe(2500) // floor(2500.25)
    expect(poolCeiling(0)).toBe(0)
  })
})

describe('contributionCeiling', () => {
  it('is 3x the member contribution, floored to whole TZS', () => {
    expect(contributionCeiling(10000)).toBe(30000)
    expect(contributionCeiling(0)).toBe(0)
  })
})

describe('maxLoan', () => {
  it('is the lower of 3x contribution and 25% pool', () => {
    // contribution binds: 3*5000=15,000 < 25% of 1,000,000=250,000
    expect(maxLoan(5000, 1000000)).toBe(15000)
    // pool binds: 25% of 200,000=50,000 < 3*50,000=150,000
    expect(maxLoan(50000, 200000)).toBe(50000)
    expect(maxLoan(0, 1000000)).toBe(0) // no contribution → no loan
    expect(maxLoan(100000, 0)).toBe(0)  // empty pool → no loan
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
