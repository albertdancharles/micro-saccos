// Meetings, attendance fines and the social fund (migration 030).
//
// Fines are DEDUCTED, not invoiced: applying them writes a negative savings
// adjustment plus a group earnings entry, so the money reaches the pool and the
// next share-out with no separate payment flow. That also makes them irreversible,
// which is why recording the register and applying the fines are two steps.

export const ATTENDANCE = ['present', 'late', 'excused', 'absent']

export async function getMeetings(supabase) {
  const { data, error } = await supabase
    .from('meetings')
    .select('*')
    .order('held_on', { ascending: false })
  if (error) throw error
  return data
}

export async function getAttendance(supabase, meetingId) {
  const { data, error } = await supabase
    .from('meeting_attendance')
    .select('*')
    .eq('meeting_id', meetingId)
  if (error) throw error
  return data
}

export async function recordMeeting(supabase, heldOn, title, minutes) {
  const { data, error } = await supabase.rpc('record_meeting', {
    p_held_on: heldOn,
    p_title: title,
    p_minutes: minutes || null,
  })
  if (error) throw error
  return data
}

export async function setAttendance(supabase, meetingId, memberId, status) {
  const { error } = await supabase.rpc('set_attendance', {
    p_meeting_id: meetingId,
    p_member_id: memberId,
    p_status: status,
  })
  if (error) throw error
}

export async function updateMinutes(supabase, meetingId, minutes) {
  const { error } = await supabase.rpc('update_meeting_minutes', {
    p_meeting_id: meetingId,
    p_minutes: minutes,
  })
  if (error) throw error
}

// Irreversible. Returns the total deducted.
export async function applyAttendanceFines(supabase, meetingId) {
  const { data, error } = await supabase.rpc('apply_attendance_fines', {
    p_meeting_id: meetingId,
  })
  if (error) throw error
  return data
}

// ---------------------------------------------------------------- social fund

export async function getSocialFund(supabase) {
  const [balanceRes, entriesRes, requestsRes] = await Promise.all([
    supabase.from('v_social_fund').select('*').single(),
    supabase
      .from('social_fund_entries')
      .select('*')
      .order('occurred_at', { ascending: false })
      .limit(50),
    supabase
      .from('social_fund_grant_requests')
      .select('*')
      .eq('status', 'pending')
      .order('created_at'),
  ])
  if (balanceRes.error) throw balanceRes.error
  return {
    balance: balanceRes.data,
    entries: entriesRes.data || [],
    pendingGrants: requestsRes.data || [],
  }
}

export async function recordSocialContribution(supabase, memberId, amount, reason) {
  const { data, error } = await supabase.rpc('record_social_contribution', {
    p_member_id: memberId,
    p_amount: amount,
    p_reason: reason,
    p_proof_url: null,
  })
  if (error) throw error
  return data
}

export async function requestSocialGrant(supabase, memberId, amount, reason) {
  const { data, error } = await supabase.rpc('request_social_grant', {
    p_member_id: memberId,
    p_amount: amount,
    p_reason: reason,
  })
  if (error) throw error
  return data
}

export async function approveSocialGrant(supabase, requestId) {
  const { error } = await supabase.rpc('approve_social_grant', { p_request_id: requestId })
  if (error) throw error
}

export async function rejectSocialGrant(supabase, requestId) {
  const { error } = await supabase.rpc('reject_social_grant', { p_request_id: requestId })
  if (error) throw error
}
