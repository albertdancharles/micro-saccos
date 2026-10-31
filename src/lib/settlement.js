// Settling the whole group's month in one action (migration 049).
//
// The sheet lists everything that has fallen due: each member's monthly fee and the
// interest on their loan. Everyone starts ticked, so the admin only has to say who
// did NOT pay. Selection is therefore held as the set of UNticked rows, which also
// means a row that appears while the sheet is open starts ticked like the others.
//
// The server owns every amount. The client names rows and states the total it was
// showing; if the two disagree nothing posts. See the header of 049 for why an amount
// must never come from here.

export const rowKey = (row) => `${row.kind}:${row.related_id}`

const isTicked = (row, unticked) => !unticked?.has(rowKey(row))

const sum = (rows, pick) => rows.reduce((total, row) => total + Number(pick(row) || 0), 0)

// The figures on the sheet, for whatever is ticked. `awaiting` is the part that will
// wait for a second admin rather than post on this signature.
export function summarise(rows, unticked) {
  const ticked = (rows || []).filter((r) => isTicked(r, unticked))
  return {
    ticked,
    members: new Set(ticked.map((r) => r.member_id)).size,
    fees: sum(ticked.filter((r) => r.kind === 'fee'), (r) => r.amount),
    interest: sum(ticked.filter((r) => r.kind === 'interest'), (r) => r.amount),
    total: sum(ticked, (r) => r.amount),
    awaiting: sum(ticked.filter((r) => r.needs_second_signature), (r) => r.amount),
  }
}

// One line per member, in the order the sheet came in. Keyed on the id, not the name:
// two members can share a name, and a loan belongs to a person.
export function membersFrom(rows, unticked) {
  const byMember = new Map()
  for (const row of rows || []) {
    if (!byMember.has(row.member_id)) byMember.set(row.member_id, [])
    byMember.get(row.member_id).push(row)
  }
  return [...byMember.entries()].map(([id, memberRows]) => {
    const ticked = memberRows.filter((r) => isTicked(r, unticked))
    return {
      id,
      name: memberRows[0].full_name,
      rows: memberRows,
      total: sum(memberRows, (r) => r.amount),
      tickedTotal: sum(ticked, (r) => r.amount),
      allTicked: ticked.length === memberRows.length,
      someTicked: ticked.length > 0,
    }
  })
}

// Splits the approvals queue into whole batches and the payments keyed on their own.
// `signable` is what this admin could sign right now, mirroring what
// approve_monthly_settlement steps over: anything they already signed, and their own
// money unless they are the overseer (041).
export function batchesFrom(pendingPayments, { isOverseer = false } = {}) {
  const byBatch = new Map()
  const loose = []
  for (const row of pendingPayments || []) {
    if (!row.settlement_batch_id) {
      loose.push(row)
      continue
    }
    if (!byBatch.has(row.settlement_batch_id)) byBatch.set(row.settlement_batch_id, [])
    byBatch.get(row.settlement_batch_id).push(row)
  }
  const batches = [...byBatch.entries()].map(([batchId, rows]) => {
    const isOwn = (r) => r.isSelf && !isOverseer
    const signable = rows.filter((r) => !r.iApproved && !isOwn(r))
    return {
      batchId,
      rows,
      total: sum(rows, (r) => r.amount_claimed),
      recordedByName: rows[0].recordedByName,
      signable: signable.length,
      signableTotal: sum(signable, (r) => r.amount_claimed),
      ownRows: rows.filter(isOwn).length,
    }
  })
  return { batches, loose }
}

export async function getSettlementSheet(supabase) {
  const { data, error } = await supabase.rpc('monthly_settlement_sheet')
  if (error) throw error
  return (data || []).map((row) => ({
    ...row,
    base: Number(row.base),
    penalty: Number(row.penalty),
    amount: Number(row.amount),
  }))
}

// All-or-nothing on the server. Returns what posted and what is waiting:
// { batch_id, settled_count, settled_total, awaiting_count, awaiting_total }.
export async function recordMonthlySettlement(supabase, tickedRows) {
  const { data, error } = await supabase.rpc('record_monthly_settlement', {
    p_entries: tickedRows.map((r) => ({ kind: r.kind, id: r.related_id })),
    p_expected_total: sum(tickedRows, (r) => r.amount),
  })
  if (error) throw error
  return data
}

// The second admin, once. Returns { signed_count, signed_total, left_count }.
export async function approveMonthlySettlement(supabase, batchId) {
  const { data, error } = await supabase.rpc('approve_monthly_settlement', {
    p_batch_id: batchId,
  })
  if (error) throw error
  return data
}

// Takes back whatever is still waiting; those rows return to the sheet.
export async function rejectMonthlySettlement(supabase, batchId, reason) {
  const { data, error } = await supabase.rpc('reject_monthly_settlement', {
    p_batch_id: batchId,
    p_reason: reason,
  })
  if (error) throw error
  return data
}
