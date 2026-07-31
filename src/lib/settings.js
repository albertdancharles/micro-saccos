// Group settings (migration 020). The group's financial rules — monthly fee, loan
// interest, penalty rate, pool fraction, contribution multiplier, loan term — are
// rows in `group_settings`, readable by every member and changeable only by 2-of-N
// admin approval.
//
// Rates that govern an EXISTING obligation are snapshotted on the row itself
// (monthly_fees.penalty_rate, loans.interest_rate, …), so these values describe
// what applies to NEW fees and loans, never what was already charged.

import {
  POOL_LOAN_FRACTION,
  CONTRIBUTION_LOAN_MULTIPLIER,
  LOAN_INTEREST_RATE,
  PENALTY_RATE,
} from './loanMath'

// Mirrors the COALESCE fallback in the SQL setting() accessor: if the table is
// missing a key (or the migration hasn't been applied yet) the app keeps behaving
// exactly as it did before settings existed, rather than rendering zeros.
export const SETTING_DEFAULTS = {
  monthly_fee_amount: 10000,
  loan_interest_rate: LOAN_INTEREST_RATE,
  penalty_rate: PENALTY_RATE,
  pool_loan_fraction: POOL_LOAN_FRACTION,
  contribution_multiplier: CONTRIBUTION_LOAN_MULTIPLIER,
  default_loan_months: 3,
}

// Which settings render as a percentage rather than a shilling amount / plain number.
export const SETTING_KIND = {
  monthly_fee_amount: 'money',
  loan_interest_rate: 'percent',
  penalty_rate: 'percent',
  pool_loan_fraction: 'percent',
  contribution_multiplier: 'multiplier',
  default_loan_months: 'months',
}

// Returns { values, rows } — `values` is the flat key→number map the app computes
// with; `rows` keeps label/min/max for the admin settings UI.
export async function getSettings(supabase) {
  const { data, error } = await supabase
    .from('group_settings')
    .select('key, value, min_value, max_value, label, updated_at')
    .order('key')
  if (error) throw error

  const values = { ...SETTING_DEFAULTS }
  for (const r of data) values[r.key] = Number(r.value)
  return { values, rows: data }
}

export async function requestSettingChange(supabase, key, newValue, reason) {
  const { data, error } = await supabase.rpc('request_setting_change', {
    p_key: key,
    p_new_value: newValue,
    p_reason: reason,
  })
  if (error) throw error
  return data
}

export async function approveSettingChange(supabase, changeId) {
  const { error } = await supabase.rpc('approve_setting_change', { p_change_id: changeId })
  if (error) throw error
}

export async function cancelSettingChange(supabase, changeId) {
  const { error } = await supabase.rpc('cancel_setting_change', { p_change_id: changeId })
  if (error) throw error
}

// Display helper shared by the settings panel, the change queue, and the modal so
// a rate is never shown as "0.05" in one place and "5%" in another.
export function formatSettingValue(key, value, formatTZS) {
  const n = Number(value)
  switch (SETTING_KIND[key]) {
    case 'money':
      return formatTZS ? formatTZS(n) : String(n)
    case 'percent':
      // Trailing zeros stripped: 0.05 → "5%", 0.125 → "12.5%".
      return `${Number((n * 100).toFixed(2))}%`
    case 'multiplier':
      return `${Number(n)}x`
    case 'months':
      return String(Number(n))
    default:
      return String(n)
  }
}
