// The sheet's arithmetic is what the admin signs against, so these pin the figures
// on screen. Everything starts ticked, which is the whole point of the feature: the
// admin says who did NOT pay, rather than saying fourteen times who did.
import { describe, expect, it, vi } from 'vitest'
import {
  batchesFrom,
  getSettlementSheet,
  membersFrom,
  recordMonthlySettlement,
  rowKey,
  summarise,
} from './settlement'

const fee = (member, name, amount = 10000, extra = {}) => ({
  kind: 'fee',
  related_id: `fee-${member}`,
  member_id: member,
  full_name: name,
  period: '2026-10-01',
  due_date: '2026-10-31',
  installment_number: null,
  base: amount,
  penalty: 0,
  amount,
  needs_second_signature: false,
  ...extra,
})

const interest = (member, name, amount, extra = {}) => ({
  kind: 'interest',
  related_id: `inst-${member}`,
  member_id: member,
  full_name: name,
  period: null,
  due_date: '2026-10-31',
  installment_number: 1,
  base: amount,
  penalty: 0,
  amount,
  needs_second_signature: true,
  ...extra,
})

const rows = [
  fee('a', 'Amani Juma'),
  interest('a', 'Amani Juma', 26635),
  fee('b', 'Neema Paulo'),
  interest('b', 'Neema Paulo', 5000),
  fee('c', 'Baraka Ally'),
]

describe('summarise', () => {
  it('counts everything when nothing is unticked', () => {
    expect(summarise(rows)).toMatchObject({
      members: 3,
      fees: 30000,
      interest: 31635,
      total: 61635,
      awaiting: 31635,
    })
  })

  it('takes an unticked row out of every figure', () => {
    const unticked = new Set([rowKey(rows[1])])
    expect(summarise(rows, unticked)).toMatchObject({
      members: 3,
      fees: 30000,
      interest: 5000,
      total: 35000,
      awaiting: 5000,
    })
  })

  it('stops counting a member once all their rows are unticked', () => {
    const unticked = new Set([rowKey(rows[4])])
    expect(summarise(rows, unticked).members).toBe(2)
  })

  it('is all zeroes for an empty sheet', () => {
    expect(summarise([])).toMatchObject({ members: 0, fees: 0, interest: 0, total: 0, awaiting: 0 })
  })
})

describe('membersFrom', () => {
  it('folds rows into one line per member, keeping the sheet order', () => {
    const members = membersFrom(rows)
    expect(members.map((m) => m.name)).toEqual(['Amani Juma', 'Neema Paulo', 'Baraka Ally'])
    expect(members[0].rows).toHaveLength(2)
    expect(members[0].total).toBe(36635)
  })

  it('separates two members who share a name', () => {
    const members = membersFrom([fee('x', 'Juma'), fee('y', 'Juma')])
    expect(members).toHaveLength(2)
  })

  it('reports how far each member is ticked, for the checkbox', () => {
    const unticked = new Set([rowKey(rows[1])])
    const [amani, neema] = membersFrom(rows, unticked)
    expect(amani).toMatchObject({ allTicked: false, someTicked: true, tickedTotal: 10000 })
    expect(neema).toMatchObject({ allTicked: true, someTicked: true, tickedTotal: 15000 })

    const none = new Set(rows.slice(0, 2).map(rowKey))
    expect(membersFrom(rows, none)[0]).toMatchObject({
      allTicked: false,
      someTicked: false,
      tickedTotal: 0,
    })
  })
})

describe('getSettlementSheet', () => {
  it('turns the numeric strings PostgREST sends into numbers', async () => {
    const supabase = {
      rpc: vi.fn().mockResolvedValue({
        data: [{ ...fee('a', 'Amani'), base: '10000.00', penalty: '500.00', amount: '10500.00' }],
        error: null,
      }),
    }
    const [row] = await getSettlementSheet(supabase)
    expect(supabase.rpc).toHaveBeenCalledWith('monthly_settlement_sheet')
    expect(row).toMatchObject({ base: 10000, penalty: 500, amount: 10500 })
  })

  it('throws what the server said', async () => {
    const supabase = { rpc: vi.fn().mockResolvedValue({ data: null, error: new Error('nope') }) }
    await expect(getSettlementSheet(supabase)).rejects.toThrow('nope')
  })
})

describe('recordMonthlySettlement', () => {
  it('sends which rows and the total shown, never an amount per row', async () => {
    const supabase = {
      rpc: vi.fn().mockResolvedValue({ data: { settled_count: 2 }, error: null }),
    }
    await recordMonthlySettlement(supabase, rows.slice(0, 2))
    expect(supabase.rpc).toHaveBeenCalledWith('record_monthly_settlement', {
      p_entries: [
        { kind: 'fee', id: 'fee-a' },
        { kind: 'interest', id: 'inst-a' },
      ],
      p_expected_total: 36635,
    })
  })
})

describe('batchesFrom', () => {
  const pending = (id, batch, amount, extra = {}) => ({
    id,
    settlement_batch_id: batch,
    amount_claimed: amount,
    memberName: 'Someone',
    recordedByName: 'Kelvin Sinde',
    iApproved: false,
    isSelf: false,
    ...extra,
  })

  it('splits batch rows from ordinary ones', () => {
    const { batches, loose } = batchesFrom([
      pending('1', 'B', 5000),
      pending('2', null, 9000),
      pending('3', 'B', '3000.00'),
    ])
    expect(loose.map((r) => r.id)).toEqual(['2'])
    expect(batches).toHaveLength(1)
    expect(batches[0]).toMatchObject({
      batchId: 'B',
      total: 8000,
      recordedByName: 'Kelvin Sinde',
    })
    expect(batches[0].rows.map((r) => r.id)).toEqual(['1', '3'])
  })

  it('knows what the viewer can sign', () => {
    const [mine] = batchesFrom([
      pending('1', 'B', 5000, { iApproved: true }),
      pending('2', 'B', 5000, { iApproved: true }),
    ]).batches
    expect(mine.signable).toBe(0)

    const [theirs] = batchesFrom([pending('1', 'B', 5000), pending('2', 'B', 3000)]).batches
    expect(theirs.signable).toBe(2)
    expect(theirs.signableTotal).toBe(8000)
  })

  it('leaves the signer\'s own row out of what they can sign', () => {
    const [batch] = batchesFrom([
      pending('1', 'B', 5000),
      pending('2', 'B', 3000, { isSelf: true }),
    ]).batches
    expect(batch.signable).toBe(1)
    expect(batch.signableTotal).toBe(5000)
    expect(batch.ownRows).toBe(1)
  })

  it('lets the overseer sign their own row', () => {
    const [batch] = batchesFrom(
      [pending('1', 'B', 5000), pending('2', 'B', 3000, { isSelf: true })],
      { isOverseer: true },
    ).batches
    expect(batch.signable).toBe(2)
    expect(batch.ownRows).toBe(0)
  })
})
