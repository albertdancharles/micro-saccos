import { describe, it, expect } from 'vitest'
import { installmentsDueNow } from './loans'
import { feesDueNow } from './fees'

// An installment as v_installment_status_money returns it — only the fields the
// rule reads.
const inst = (n, dueDate, status = 'pending') => ({
  installment_number: n,
  due_date: dueDate,
  computed_status: status,
})

// The group meets on the last Saturday. October 2026's meeting is the 31st, which
// is also the last day of the month; November's is the 28th, two days before it.
const OCT = inst(1, '2026-10-31')
const NOV = inst(2, '2026-11-28')

describe('installmentsDueNow', () => {
  it('does not count an installment before its meeting day', () => {
    // The 1st, mid-month, and the day before: the repayment is handed over at the
    // meeting, so until then the member has had no occasion to pay it.
    expect(installmentsDueNow([OCT], '2026-10-01')).toEqual([])
    expect(installmentsDueNow([OCT], '2026-10-07')).toEqual([])
    expect(installmentsDueNow([OCT], '2026-10-30')).toEqual([])
  })

  it('counts it on the meeting day itself', () => {
    expect(installmentsDueNow([OCT], '2026-10-31')).toHaveLength(1)
  })

  it('keeps counting it once it is past due', () => {
    expect(installmentsDueNow([OCT], '2026-11-01')).toHaveLength(1)
    expect(installmentsDueNow([OCT], '2026-12-20')).toHaveLength(1)
    // And the status the view computes says the same thing.
    expect(installmentsDueNow([inst(1, '2026-10-31', 'overdue')], '2026-11-05')).toHaveLength(1)
  })

  it('never counts a settled installment', () => {
    expect(installmentsDueNow([inst(1, '2026-10-31', 'paid')], '2027-06-01')).toEqual([])
  })

  it('never counts a cancelled installment, even once past due', () => {
    // Cancelled rows are historical (022) — a record of a schedule that was
    // restated, not money anybody owes.
    expect(installmentsDueNow([inst(1, '2026-10-31', 'cancelled')], '2027-06-01')).toEqual([])
  })

  it('counts a part-paid installment only once its due date has arrived', () => {
    const partial = inst(1, '2026-10-31', 'partial')
    expect(installmentsDueNow([partial], '2026-10-30')).toEqual([])
    expect(installmentsDueNow([partial], '2026-10-31')).toHaveLength(1)
  })

  it('splits a schedule at today', () => {
    // The real shape of a loan disbursed at the 26 September meeting: three
    // installments at the next three meetings. On 7 October none of them is
    // payable yet.
    const schedule = [OCT, NOV, inst(3, '2026-12-26')]
    expect(installmentsDueNow(schedule, '2026-10-07')).toEqual([])
    expect(installmentsDueNow(schedule, '2026-10-31')).toEqual([OCT])
    expect(installmentsDueNow(schedule, '2026-11-28')).toEqual([OCT, NOV])
  })

  it('handles an empty or missing schedule', () => {
    expect(installmentsDueNow([], '2026-10-31')).toEqual([])
    expect(installmentsDueNow(undefined, '2026-10-31')).toEqual([])
    expect(installmentsDueNow(null, '2026-10-31')).toEqual([])
  })
})

// The defect this rule was written to close: a fee and an installment falling due
// at the SAME meeting used to get different answers, so the dashboard's "amount
// due" carried the repayment for four weeks before the member could pay it while
// leaving out the fee collected at that very meeting.
describe('a fee and an installment due at the same meeting agree', () => {
  const fee = { period: '2026-10-01', due_date: '2026-10-31', computed_status: 'pending' }
  const repayment = OCT

  it('neither counts before the meeting', () => {
    expect(feesDueNow([fee], '2026-10-07')).toEqual([])
    expect(installmentsDueNow([repayment], '2026-10-07')).toEqual([])
  })

  it('both count on the meeting day', () => {
    expect(feesDueNow([fee], '2026-10-31')).toHaveLength(1)
    expect(installmentsDueNow([repayment], '2026-10-31')).toHaveLength(1)
  })
})
