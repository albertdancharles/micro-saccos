import { describe, it, expect } from 'vitest'
import { allocateFeePayment, allocateInstallmentPayment } from './allocation'

// A 10,000 fee, untouched, two months overdue at 5% → 1,000 penalty.
const freshFee = { amount: 10000, amount_paid: 0, penalty_due: 1000 }

describe('allocateFeePayment', () => {
  it('settles the penalty before the base', () => {
    const a = allocateFeePayment(1500, freshFee)
    expect(a.penalty).toBe(1000)
    expect(a.base).toBe(500)
    expect(a.remaining).toBe(9500)
    expect(a.status).toBe('partial')
  })

  it('marks the fee paid only when nothing is left', () => {
    const a = allocateFeePayment(11000, freshFee)
    expect(a.penalty).toBe(1000)
    expect(a.base).toBe(10000)
    expect(a.remaining).toBe(0)
    expect(a.excess).toBe(0)
    expect(a.status).toBe('paid')
  })

  it('reports anything it cannot allocate as excess', () => {
    const a = allocateFeePayment(12000, freshFee)
    expect(a.excess).toBe(1000)
  })

  it('picks up where an earlier partial payment stopped', () => {
    // 4,000 already paid; penalty now accrues on the 6,000 still owed.
    const partlyPaid = { amount: 10000, amount_paid: 4000, penalty_due: 600 }
    const a = allocateFeePayment(6600, partlyPaid)
    expect(a.penalty).toBe(600)
    expect(a.base).toBe(6000)
    expect(a.status).toBe('paid')
  })

  it('puts a payment smaller than the penalty entirely toward the penalty', () => {
    const a = allocateFeePayment(400, freshFee)
    expect(a).toMatchObject({ penalty: 400, base: 0, excess: 0, status: 'partial' })
  })
})

// Interest-only installment on a 100,000 loan at 5%, one month overdue (250 penalty).
const interestOnly = {
  interest_due: 5000,
  interest_paid: 0,
  principal_due: 0,
  principal_paid: 0,
  penalty_due: 250,
}

describe('allocateInstallmentPayment', () => {
  it('runs penalty → interest → principal', () => {
    const a = allocateInstallmentPayment(5250, interestOnly, 100000)
    expect(a).toMatchObject({ penalty: 250, interest: 5000, principal: 0, extraPrincipal: 0 })
    expect(a.status).toBe('paid')
    expect(a.outstandingAfter).toBe(100000)
  })

  it('retires principal early with anything above the contracted amount', () => {
    const a = allocateInstallmentPayment(25250, interestOnly, 100000)
    expect(a.penalty).toBe(250)
    expect(a.interest).toBe(5000)
    expect(a.extraPrincipal).toBe(20000)
    expect(a.outstandingAfter).toBe(80000)
    expect(a.excess).toBe(0)
  })

  it('leaves the row partial when the interest is not fully covered', () => {
    const a = allocateInstallmentPayment(3000, interestOnly, 100000)
    expect(a.penalty).toBe(250)
    expect(a.interest).toBe(2750)
    expect(a.remaining).toBe(2250)
    expect(a.status).toBe('partial')
    expect(a.outstandingAfter).toBe(100000)
  })

  it('caps principal at the outstanding balance and reports the rest as excess', () => {
    const final = {
      interest_due: 5000,
      interest_paid: 0,
      principal_due: 100000,
      principal_paid: 0,
      penalty_due: 0,
    }
    const a = allocateInstallmentPayment(120000, final, 100000)
    expect(a.principal).toBe(100000)
    expect(a.extraPrincipal).toBe(0)
    expect(a.excess).toBe(15000)
    expect(a.outstandingAfter).toBe(0)
    expect(a.ceiling).toBe(105000)
  })

  it('never double-counts principal already repaid early', () => {
    // 30,000 of principal was retired ahead of schedule on this same row.
    const row = {
      interest_due: 5000,
      interest_paid: 5000,
      principal_due: 0,
      principal_paid: 30000,
      penalty_due: 0,
    }
    const a = allocateInstallmentPayment(10000, row, 70000)
    expect(a.interest).toBe(0)
    expect(a.principal).toBe(0)
    expect(a.extraPrincipal).toBe(10000)
    expect(a.outstandingAfter).toBe(60000)
  })
})
