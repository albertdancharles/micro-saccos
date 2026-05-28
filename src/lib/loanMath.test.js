import { describe, it, expect } from 'vitest'
import { poolCeiling, maxLoan, monthlyInterest, penaltyDue } from './loanMath'

describe('poolCeiling / maxLoan', () => {
  it('is 25% of the pool, floored to whole TZS', () => {
    expect(poolCeiling(1000000)).toBe(250000)
    expect(poolCeiling(10000)).toBe(2500)
    expect(poolCeiling(10001)).toBe(2500) // floor(2500.25)
    expect(poolCeiling(0)).toBe(0)
  })

  it('maxLoan returns the pool ceiling (sole rule)', () => {
    expect(maxLoan(10000)).toBe(2500)
    expect(maxLoan(0)).toBe(0)
    expect(maxLoan(1000000)).toBe(250000)
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
