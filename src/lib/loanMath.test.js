import { describe, it, expect } from 'vitest'
import { loanCeiling, poolCeiling, maxLoan, monthlyInterest, penaltyDue } from './loanMath'

describe('loanCeiling', () => {
  it('is 5x approved savings', () => {
    expect(loanCeiling(20000)).toBe(100000)
    expect(loanCeiling(0)).toBe(0)
  })
})

describe('poolCeiling', () => {
  it('is 25% of the pool, floored to whole TZS', () => {
    expect(poolCeiling(1000000)).toBe(250000)
    expect(poolCeiling(10000)).toBe(2500)
    expect(poolCeiling(10001)).toBe(2500) // floor(2500.25)
    expect(poolCeiling(0)).toBe(0)
  })
})

describe('maxLoan', () => {
  it('is the lower of the 5x savings ceiling and the 25% pool ceiling', () => {
    // savings binds: 5*20000=100000 < 25% of 1,000,000=250000
    expect(maxLoan(20000, 1000000)).toBe(100000)
    // pool binds: 25% of 200000=50000 < 5*20000=100000
    expect(maxLoan(20000, 200000)).toBe(50000)
    // small pool throttles even a well-saved member
    expect(maxLoan(50000, 10000)).toBe(2500)
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
