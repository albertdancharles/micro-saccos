// Cycles & share-out (migrations 023–024).
//
// A cycle is the group's financial year. Closing it freezes each member's
// time-weighted share into `distributions` rows — snapshotted, so a later savings
// correction can never restate a share-out the group already agreed.

export async function getCycles(supabase) {
  const { data, error } = await supabase
    .from('cycles')
    .select('*')
    .order('start_date', { ascending: false })
  if (error) throw error
  return data
}

export async function getOpenCycle(supabase) {
  const { data, error } = await supabase
    .from('cycles')
    .select('*')
    .eq('status', 'open')
    .maybeSingle()
  if (error) throw error
  return data
}

// { interest_tzs, penalty_tzs, write_off_tzs, net_tzs } for one cycle.
export async function getCycleEarnings(supabase, cycleId) {
  const { data, error } = await supabase.rpc('cycle_earnings', { p_cycle_id: cycleId })
  if (error) throw error
  return data?.[0] ?? { interest_tzs: 0, penalty_tzs: 0, write_off_tzs: 0, net_tzs: 0 }
}

// Exactly what close_cycle would write, without writing it. The wizard renders
// this so nobody votes on a split they haven't seen.
export async function previewCycleClose(supabase, cycleId, mode) {
  const { data, error } = await supabase.rpc('preview_cycle_close', {
    p_cycle_id: cycleId,
    p_mode: mode,
  })
  if (error) throw error
  return data
}

export async function getDistributions(supabase, cycleId = null) {
  let q = supabase.from('distributions').select('*')
  if (cycleId) q = q.eq('cycle_id', cycleId)
  const { data, error } = await q
  if (error) throw error
  return data
}

export async function getPendingClosures(supabase) {
  const { data, error } = await supabase
    .from('cycle_closures')
    .select('*')
    .eq('status', 'pending')
    .order('created_at', { ascending: true })
  if (error) throw error
  return data
}

export async function requestCycleClose(supabase, cycleId, mode, reason) {
  const { data, error } = await supabase.rpc('request_cycle_close', {
    p_cycle_id: cycleId,
    p_mode: mode,
    p_reason: reason,
  })
  if (error) throw error
  return data
}

export async function approveCycleClose(supabase, closureId) {
  const { error } = await supabase.rpc('approve_cycle_close', { p_closure_id: closureId })
  if (error) throw error
}

export async function cancelCycleClose(supabase, closureId) {
  const { error } = await supabase.rpc('cancel_cycle_close', { p_closure_id: closureId })
  if (error) throw error
}

export async function markDistributionPaid(supabase, distributionId, proofUrl) {
  const { error } = await supabase.rpc('mark_distribution_paid', {
    p_distribution_id: distributionId,
    p_proof_url: proofUrl,
  })
  if (error) throw error
}

export async function updateCycleDates(supabase, cycleId, start, end, name) {
  const { error } = await supabase.rpc('update_cycle_dates', {
    p_cycle_id: cycleId,
    p_start: start,
    p_end: end,
    p_name: name,
  })
  if (error) throw error
}
