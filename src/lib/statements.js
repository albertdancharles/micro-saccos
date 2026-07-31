// CSV statement helper (Phase 4). Builds a multi-section CSV of a member's
// savings deposits, monthly fees, loans, installments, money paid back out to
// them, and full submission history. Member RLS restricts every query to their
// own rows, so this works as a self-download from the Profile page.

function csvEscape(v) {
  if (v == null) return ''
  const s = String(v)
  if (/[",\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`
  return s
}

const row = (cells) => cells.map(csvEscape).join(',')
const day = (s) => (s ? String(s).slice(0, 10) : '')

export async function buildMemberStatement(supabase, { memberId, memberName, memberEmail }) {
  const [savingsRes, allSubsRes, feesRes, loansRes, instRes, payoutsRes, withdrawalsRes] =
    await Promise.all([
      supabase
        .from('payment_submissions')
        .select('submitted_at, amount_claimed, status, reviewed_at')
        .eq('member_id', memberId)
        .eq('submission_type', 'savings_deposit')
        .order('submitted_at', { ascending: true }),
      supabase
        .from('payment_submissions')
        .select(
          'submitted_at, submission_type, amount_claimed, status, reviewed_at, rejection_reason',
        )
        .eq('member_id', memberId)
        .order('submitted_at', { ascending: true }),
      supabase
        .from('monthly_fees')
        .select('period, amount, amount_paid, status, paid_at, penalty_collected')
        .eq('member_id', memberId)
        .order('period', { ascending: true }),
      supabase
        .from('loans')
        .select('id, principal, status, requested_at, approved_at, disbursed_at, rejection_reason')
        .eq('member_id', memberId)
        .order('requested_at', { ascending: true }),
      // RLS scopes loan_installments to the caller's own loans, so no client filter is needed.
      supabase
        .from('loan_installments')
        .select(
          'loan_id, installment_number, due_date, total_due, interest_paid, principal_paid, penalty_collected, status, paid_at',
        )
        .order('due_date', { ascending: true }),
      // Money out (migrations 024/025). Kept OUT of the throw loop below so the
      // statement still downloads on a database where those aren't applied yet.
      supabase
        .from('distributions')
        .select('cycle_id, earnings_tzs, capital_returned_tzs, total_payout_tzs, status, paid_at')
        .eq('member_id', memberId),
      supabase
        .from('withdrawal_requests')
        .select('created_at, amount, reason, status, paid_at')
        .eq('member_id', memberId)
        .order('created_at', { ascending: true }),
    ])
  for (const r of [savingsRes, allSubsRes, feesRes, loansRes, instRes]) {
    if (r.error) throw r.error
  }

  const lines = []
  lines.push(row(['Statement for', memberName || '']))
  lines.push(row(['Email', memberEmail || '']))
  lines.push(row(['Generated', day(new Date().toISOString())]))
  lines.push('')

  const approvedSavings = savingsRes.data.filter((s) => s.status === 'approved')
  lines.push('Approved savings deposits')
  lines.push(row(['Date', 'Amount']))
  for (const s of approvedSavings) lines.push(row([day(s.submitted_at), s.amount_claimed]))
  const savingsTotal = approvedSavings.reduce((sum, s) => sum + Number(s.amount_claimed), 0)
  lines.push(row(['Total', savingsTotal]))
  lines.push('')

  // Since partial payments (migration 021) a fee can be part-settled, so the
  // statement reports what was actually banked, not just the contracted amount.
  lines.push('Monthly fees')
  lines.push(row(['Period', 'Amount', 'Paid', 'Penalty collected', 'Status', 'Paid at']))
  for (const f of feesRes.data) {
    lines.push(
      row([day(f.period), f.amount, f.amount_paid, f.penalty_collected, f.status, day(f.paid_at)]),
    )
  }
  const paidFeesTotal = feesRes.data.reduce((sum, f) => sum + Number(f.amount_paid || 0), 0)
  lines.push(row(['Total paid (base)', paidFeesTotal]))
  lines.push('')

  lines.push('Loans')
  lines.push(
    row(['Loan ID', 'Principal', 'Status', 'Requested', 'Approved', 'Disbursed', 'Rejection reason']),
  )
  for (const l of loansRes.data) {
    lines.push(
      row([
        l.id,
        l.principal,
        l.status,
        day(l.requested_at),
        day(l.approved_at),
        day(l.disbursed_at),
        l.rejection_reason || '',
      ]),
    )
  }
  lines.push('')

  lines.push('Loan installments')
  lines.push(
    row([
      'Loan ID',
      'Installment #',
      'Due',
      'Total due',
      'Interest paid',
      'Principal paid',
      'Penalty collected',
      'Status',
      'Paid at',
    ]),
  )
  for (const i of instRes.data) {
    lines.push(
      row([
        i.loan_id,
        i.installment_number,
        day(i.due_date),
        i.total_due,
        i.interest_paid,
        i.principal_paid,
        i.penalty_collected,
        i.status,
        day(i.paid_at),
      ]),
    )
  }
  lines.push('')

  // Money OUT (migrations 024/025). Absent tables mean those migrations aren't
  // applied yet — the statement just omits the sections rather than failing.
  if (payoutsRes && !payoutsRes.error && payoutsRes.data?.length) {
    lines.push('Share-outs')
    lines.push(row(['Cycle', 'Earnings', 'Capital returned', 'Total', 'Status', 'Paid at']))
    for (const d of payoutsRes.data) {
      lines.push(
        row([
          d.cycle_id,
          d.earnings_tzs,
          d.capital_returned_tzs,
          d.total_payout_tzs,
          d.status,
          day(d.paid_at),
        ]),
      )
    }
    lines.push('')
  }

  if (withdrawalsRes && !withdrawalsRes.error && withdrawalsRes.data?.length) {
    lines.push('Withdrawals')
    lines.push(row(['Requested', 'Amount', 'Reason', 'Status', 'Paid at']))
    for (const w of withdrawalsRes.data) {
      lines.push(row([day(w.created_at), w.amount, w.reason, w.status, day(w.paid_at)]))
    }
    lines.push('')
  }

  lines.push('Submission history (all types)')
  lines.push(row(['Date', 'Type', 'Amount claimed', 'Status', 'Reviewed at', 'Rejection reason']))
  for (const s of allSubsRes.data) {
    lines.push(
      row([
        day(s.submitted_at),
        s.submission_type,
        s.amount_claimed,
        s.status,
        day(s.reviewed_at),
        s.rejection_reason || '',
      ]),
    )
  }

  const csv = lines.join('\n')
  return new Blob([csv], { type: 'text/csv;charset=utf-8' })
}

export function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  URL.revokeObjectURL(url)
}
