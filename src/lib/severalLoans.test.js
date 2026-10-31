import { describe, it, expect } from 'vitest'
import { quarterEndAfter } from './meetings'
import { remainingLoanRoom } from './loanMath'
import { combineInstallments, loanLabel, summariseLoans } from './loans'

// Local dates, the way lastMeetingOnOrBefore reads them.
const on = (y, m, d) => new Date(y, m - 1, d)

describe('quarterEndAfter', () => {
  // The same table as 24_several_loans.test.sql. It is the twin of loan_term_months.
  it.each([
    [on(2026, 9, 26), 3, '2026-12-26'],
    [on(2026, 10, 31), 2, '2026-12-26'],
    [on(2026, 11, 28), 1, '2026-12-26'],
    [on(2026, 12, 26), 3, '2027-03-27'],
    [on(2027, 1, 30), 2, '2027-03-27'],
    [on(2027, 2, 27), 1, '2027-03-27'],
    [on(2027, 3, 27), 3, '2027-06-26'],
    [on(2027, 8, 28), 1, '2027-09-25'],
  ])('at the meeting of %s the loan runs %i months to %s', (today, months, dueDate) => {
    expect(quarterEndAfter(today)).toEqual({ months, dueDate })
  })

  it('counts from the meeting just gone when the loan is recorded late', () => {
    expect(quarterEndAfter(on(2026, 11, 2))).toEqual({ months: 2, dueDate: '2026-12-26' })
    expect(quarterEndAfter(on(2027, 1, 5))).toEqual({ months: 3, dueDate: '2027-03-27' })
  })
})

describe('remainingLoanRoom', () => {
  it('takes what is owed and what is pending off the ceiling', () => {
    expect(remainingLoanRoom(1067333)).toBe(1067333)
    expect(remainingLoanRoom(1067333, 500000)).toBe(567333)
    expect(remainingLoanRoom(1067333, 500000, 67333)).toBe(500000)
  })

  it('never goes below zero', () => {
    // Savings can fall after a loan is issued, leaving a member over their ceiling.
    expect(remainingLoanRoom(100000, 500000)).toBe(0)
  })
})

describe('summariseLoans', () => {
  it('adds up every loan, counting active balances and pending principal apart', () => {
    const summary = summariseLoans([
      { status: 'active', principal: 300000, outstanding_principal: 250000 },
      { status: 'active', principal: 200000, outstanding_principal: 200000 },
      { status: 'pending', principal: 110000, outstanding_principal: 0 },
    ])
    expect(summary).toEqual({
      owed: 450000,
      pending: 110000,
      activeCount: 2,
      pendingCount: 1,
      repaid: 50000,
    })
  })

  it('is all zeroes with no loans', () => {
    expect(summariseLoans([])).toEqual({
      owed: 0,
      pending: 0,
      activeCount: 0,
      pendingCount: 0,
      repaid: 0,
    })
  })
})

describe('loanLabel', () => {
  const t = (s) => s

  it('tells two loans of the same amount apart by the month they were issued', () => {
    const october = loanLabel({ principal: 100000, disbursed_at: '2026-10-31T09:00:00Z' }, t)
    const november = loanLabel({ principal: 100000, disbursed_at: '2026-11-28T09:00:00Z' }, t)
    expect(october).toContain('100,000')
    expect(october).toContain('Oct 2026')
    expect(october).not.toBe(november)
  })

  it('has no month for a loan not yet issued', () => {
    const label = loanLabel({ principal: 100000, disbursed_at: null }, t)
    expect(label).toContain('100,000')
    expect(label).not.toContain('(')
  })
})

describe('combineInstallments', () => {
  const inst = (status, total) => ({ computed_status: status, total_with_penalty: total })

  it('is nothing when nothing is due this month', () => {
    expect(combineInstallments([])).toBeNull()
  })

  it('passes a single installment through untouched', () => {
    const only = inst('pending', 5500)
    expect(combineInstallments([only])).toBe(only)
  })

  it('adds the money and reports the worst status', () => {
    expect(combineInstallments([inst('paid', 5500), inst('overdue', 10000)])).toEqual({
      computed_status: 'overdue',
      total_with_penalty: 15500,
    })
    expect(combineInstallments([inst('paid', 5500), inst('pending', 10000)])).toEqual({
      computed_status: 'pending',
      total_with_penalty: 15500,
    })
  })

  it('is paid only when all of them are', () => {
    expect(combineInstallments([inst('paid', 5500), inst('paid', 10000)]).computed_status).toBe('paid')
  })

  it('ignores cancelled rows, which are history', () => {
    const live = inst('pending', 5500)
    expect(combineInstallments([inst('cancelled', 9999), live])).toBe(live)
  })
})
