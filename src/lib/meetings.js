// Meetings, attendance fines and the social fund (migration 030).
//
// Fines are DEDUCTED, not invoiced: applying them writes a negative savings
// adjustment plus a group earnings entry, so the money reaches the pool and the
// next share-out with no separate payment flow. That also makes them irreversible,
// which is why recording the register and applying the fines are two steps.

export const ATTENDANCE = ['present', 'late', 'excused', 'absent']

// ------------------------------------------------------------- the meeting day
//
// The group meets on the LAST SATURDAY of every month. That is the same rule as
// meeting_day() in migration 043 — kept in both places because the server needs
// it to set loan due dates and the client needs it to fill in a date field.
// Change one, change the other.

// The last Saturday of `monthIndex` (0-based) in `year`, as a day number.
// getDay() is 0 for Sunday and 6 for Saturday, so (day + 1) % 7 is the number
// of days back to Saturday — 0 when the month already ends on one.
function lastSaturdayOf(year, monthIndex) {
  const last = new Date(year, monthIndex + 1, 0)
  return last.getDate() - ((last.getDay() + 1) % 7)
}

function isoDate(year, monthIndex, day) {
  return `${year}-${String(monthIndex + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`
}

// The most recent meeting on or before `today`, as 'YYYY-MM-DD'.
//
// Not simply "this month's last Saturday": record_meeting rejects a future date,
// and for most of a month that Saturday has not happened yet — on the 5th of a
// month the meeting to record is still last month's.
export function lastMeetingOnOrBefore(today = new Date()) {
  const year = today.getFullYear()
  const monthIndex = today.getMonth()
  const thisMonth = lastSaturdayOf(year, monthIndex)
  if (thisMonth <= today.getDate()) return isoDate(year, monthIndex, thisMonth)

  const prevYear = monthIndex === 0 ? year - 1 : year
  const prevMonth = monthIndex === 0 ? 11 : monthIndex - 1
  return isoDate(prevYear, prevMonth, lastSaturdayOf(prevYear, prevMonth))
}

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
