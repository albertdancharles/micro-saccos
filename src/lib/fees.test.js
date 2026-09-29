import { describe, it, expect } from 'vitest'
import { feesDueNow, todayEAT } from './fees'

// A fee as v_fee_status_money returns it — only the fields the rule reads.
const fee = (period, dueDate, status = 'pending') => ({
  period,
  due_date: dueDate,
  computed_status: status,
})

// November 2026 is the month where the meeting (Sat 28th) and the old
// last-day-of-month rule (Mon 30th) actually differ, so it is the one worth
// testing around. See migration 044.
const NOV = fee('2026-11-01', '2026-11-28')

describe('feesDueNow', () => {
  it('does not count a fee before its meeting day', () => {
    // The 1st, the 15th, and the day before the meeting: the member has had no
    // occasion to hand the money over, so nothing is owed yet.
    expect(feesDueNow([NOV], '2026-11-01')).toEqual([])
    expect(feesDueNow([NOV], '2026-11-15')).toEqual([])
    expect(feesDueNow([NOV], '2026-11-27')).toEqual([])
  })

  it('counts it on the meeting day itself', () => {
    expect(feesDueNow([NOV], '2026-11-28')).toHaveLength(1)
  })

  it('keeps counting it after the meeting has passed', () => {
    expect(feesDueNow([NOV], '2026-11-29')).toHaveLength(1)
    expect(feesDueNow([NOV], '2026-12-20')).toHaveLength(1)
  })

  it('never counts a settled fee, even long past its due date', () => {
    const paid = fee('2026-11-01', '2026-11-28', 'paid')
    expect(feesDueNow([paid], '2027-06-01')).toEqual([])
  })

  it('counts an overdue fee — it is past its due date by definition', () => {
    const overdue = fee('2026-11-01', '2026-11-28', 'overdue')
    expect(feesDueNow([overdue], '2026-12-05')).toHaveLength(1)
  })

  it('counts a part-paid fee once the meeting has come', () => {
    const partial = fee('2026-11-01', '2026-11-28', 'partial')
    expect(feesDueNow([partial], '2026-11-27')).toEqual([])
    expect(feesDueNow([partial], '2026-11-28')).toHaveLength(1)
  })

  it('splits a mixed history at today, not at the month boundary', () => {
    // Two collected months, one owed from November, and December not yet met.
    const fees = [
      fee('2026-12-01', '2026-12-26'),
      fee('2026-11-01', '2026-11-28', 'overdue'),
      fee('2026-10-01', '2026-10-31', 'paid'),
      fee('2026-09-01', '2026-09-30', 'paid'),
    ]
    const due = feesDueNow(fees, '2026-12-10')
    expect(due).toHaveLength(1)
    expect(due[0].period).toBe('2026-11-01')
  })

  it('handles the September/October cutover dates from migration 044', () => {
    // September keeps the old last-day rule; October's meeting IS the month end.
    const sep = fee('2026-09-01', '2026-09-30')
    const oct = fee('2026-10-01', '2026-10-31')
    expect(feesDueNow([sep, oct], '2026-10-30')).toEqual([sep])
    expect(feesDueNow([sep, oct], '2026-10-31')).toEqual([sep, oct])
  })

  it('tolerates an empty or missing list', () => {
    expect(feesDueNow([], '2026-11-28')).toEqual([])
    expect(feesDueNow(undefined, '2026-11-28')).toEqual([])
    expect(feesDueNow(null, '2026-11-28')).toEqual([])
  })
})

describe('todayEAT', () => {
  it('returns a YYYY-MM-DD string that sorts against DB dates', () => {
    expect(todayEAT()).toMatch(/^\d{4}-\d{2}-\d{2}$/)
  })

  it('reports the date in Dar es Salaam, not the browser', () => {
    // 22:30 UTC on the 27th is already 01:30 on the 28th in EAT (UTC+3) — the
    // meeting day. A member opening the app that evening must see the fee as due.
    const realNow = Date.now
    try {
      Date.now = () => Date.parse('2026-11-27T22:30:00Z')
      // Intl reads the Date object, so pin that rather than Date.now alone.
      const at = new Date('2026-11-27T22:30:00Z')
      const eat = new Intl.DateTimeFormat('en-CA', {
        timeZone: 'Africa/Dar_es_Salaam',
      }).format(at)
      expect(eat).toBe('2026-11-28')
      expect(feesDueNow([NOV], eat)).toHaveLength(1)
    } finally {
      Date.now = realNow
    }
  })
})
