// CSV statement helper (Phase 4). Builds a multi-section CSV of a member's
// savings deposits, monthly fees, loans, installments, and full submission
// history. Member RLS restricts every query to their own rows, so this works
// as a self-download from the Profile page.

function csvEscape(v) {
  if (v == null) return ''
  const s = String(v)
  if (/[",\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`
  return s
}

const row = (cells) => cells.map(csvEscape).join(',')
const day = (s) => (s ? String(s).slice(0, 10) : '')

export async function buildMemberStatement(supabase, { memberId, memberName, memberEmail }) {
  const [savingsRes, allSubsRes, feesRes, loansRes, instRes] = await Promise.all([
    supabase
      .from('payment_submissions')
      .select('submitted_at, amount_claimed, status, reviewed_at')
      .eq('member_id', memberId)
      .eq('submission_type', 'savings_deposit')
      .order('submitted_at', { ascending: true }),
    supabase
      .from('payment_submissions')
      .select('submitted_at, submission_type, amount_claimed, status, reviewed_at, rejection_reason')
      .eq('member_id', memberId)
      .order('submitted_at', { ascending: true }),
    supabase
      .from('monthly_fees')
      .select('period, amount, status, paid_at, penalty_collected')
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
      .select('loan_id, installment_number, due_date, total_due, penalty_collected, status, paid_at')
      .order('due_date', { ascending: true }),
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

  lines.push('Monthly fees')
  lines.push(row(['Period', 'Amount', 'Penalty collected', 'Status', 'Paid at']))
  for (const f of feesRes.data) {
    lines.push(row([day(f.period), f.amount, f.penalty_collected, f.status, day(f.paid_at)]))
  }
  const paidFeesTotal = feesRes.data
    .filter((f) => f.status === 'paid')
    .reduce((sum, f) => sum + Number(f.amount), 0)
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
  lines.push(row(['Loan ID', 'Installment #', 'Due', 'Total due', 'Penalty collected', 'Status', 'Paid at']))
  for (const i of instRes.data) {
    lines.push(
      row([
        i.loan_id,
        i.installment_number,
        day(i.due_date),
        i.total_due,
        i.penalty_collected,
        i.status,
        day(i.paid_at),
      ]),
    )
  }
  lines.push('')

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
