import { describe, it, expect } from 'vitest'
import { loanCeiling, monthlyInterest, penaltyDue } from './loanMath'

describe('loanCeiling', () => {
  it('is 5x approved savings', () => {
    expect(loanCeiling(20000)).toBe(100000)
    expect(loanCeiling(0)).toBe(0)
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
