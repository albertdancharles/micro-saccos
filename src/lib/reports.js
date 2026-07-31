// Group accounts (migration 029) — the numbers read out at an annual meeting.
//
// The balance sheet shares its identity with v_pool_reconciliation (027), so the
// report and the books-balance warning can never tell the group different stories.

import { formatTZS } from './format'

export async function getIncomeStatement(supabase, from, to) {
  const { data, error } = await supabase.rpc('group_income_statement', {
    p_from: from,
    p_to: to,
  })
  if (error) throw error
  return data?.[0] ?? null
}

export async function getBalanceSheet(supabase, asOf = null) {
  const { data, error } = await supabase.rpc('group_balance_sheet', { p_as_of: asOf })
  if (error) throw error
  return data?.[0] ?? null
}

export async function getMemberReport(supabase, asOf = null) {
  const { data, error } = await supabase.rpc('group_member_report', { p_as_of: asOf })
  if (error) throw error
  return data || []
}

export async function getMemberLedger(supabase, memberId, from = null, to = null) {
  const { data, error } = await supabase.rpc('member_ledger', {
    p_member: memberId,
    p_from: from,
    p_to: to,
  })
  if (error) throw error
  return data || []
}

// The whole pack as one CSV, for printing or emailing round before the meeting.
// Reuses the same escaping rules as the member statement.
function csvEscape(v) {
  if (v == null) return ''
  const s = String(v)
  if (/[",\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`
  return s
}
const row = (cells) => cells.map(csvEscape).join(',')

export function buildGroupReportCsv({ from, to, income, balance, members }) {
  const lines = []
  lines.push(row(['Micro-SACCOS — group report']))
  lines.push(row(['Period', `${from} to ${to}`]))
  lines.push(row(['Generated', new Date().toISOString().slice(0, 10)]))
  lines.push('')

  if (income) {
    lines.push('Income statement')
    lines.push(row(['Interest earned', income.interest_tzs]))
    lines.push(row(['Penalties collected', income.penalty_tzs]))
    lines.push(row(['Written off', income.write_off_tzs]))
    lines.push(row(['Net earnings', income.net_tzs]))
    lines.push(row(['Loans issued (count)', income.loans_issued]))
    lines.push(row(['Loans issued (value)', income.loans_issued_tzs]))
    lines.push(row(['Fee payments received', income.fees_collected_tzs]))
    lines.push('')
  }

  if (balance) {
    lines.push('Balance sheet')
    lines.push(row(['As at', balance.as_of]))
    lines.push(row(['Pool (cash)', balance.pool_tzs]))
    lines.push(row(['Out on loans', balance.outstanding_tzs]))
    lines.push(row(['Total assets', balance.total_assets_tzs]))
    lines.push(row(['Member capital', balance.member_capital_tzs]))
    lines.push(row(['Retained earnings', balance.retained_earnings_tzs]))
    lines.push(row(['Distributions paid', balance.distributions_paid_tzs]))
    lines.push(row(['Total claims', balance.total_claims_tzs]))
    lines.push(row(['Difference', balance.difference_tzs]))
    lines.push('')
  }

  if (members?.length) {
    lines.push('Members')
    lines.push(
      row(['Name', 'Role', 'Capital', 'Outstanding loan', 'Fees paid', 'Penalties paid', 'Last payout']),
    )
    for (const m of members) {
      lines.push(
        row([
          m.full_name,
          m.role,
          m.capital_tzs,
          m.outstanding_tzs,
          m.fees_paid_tzs,
          m.penalties_tzs,
          m.last_payout_tzs,
        ]),
      )
    }
  }

  return new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8' })
}

// Default reporting window: the open cycle if there is one, otherwise the last
// twelve months. A group's accounts are almost always read per cycle.
export function defaultPeriod(openCycle) {
  if (openCycle) return { from: openCycle.start_date, to: openCycle.end_date }
  const to = new Date()
  const from = new Date(to)
  from.setFullYear(from.getFullYear() - 1)
  return { from: from.toISOString().slice(0, 10), to: to.toISOString().slice(0, 10) }
}

export const money = formatTZS
