// Status badge (build plan §9). Covers obligation statuses (paid/pending/overdue/
// upcoming/cancelled/na) and submission statuses (approved/pending/rejected).
// Uses an inset ring instead of a solid background so badges read as pills on
// any background (cards, table rows, modals) — UI/UX Pro Max §6 semantic color
// + state clarity. Tone-paired text/ring keeps contrast >= 4.5:1.
import { useLanguage } from '../../hooks/useLanguage'

const STYLES = {
  paid:      'bg-emerald-50 text-emerald-700 ring-emerald-200',
  approved:  'bg-emerald-50 text-emerald-700 ring-emerald-200',
  pending:   'bg-amber-50 text-amber-700 ring-amber-200',
  overdue:   'bg-red-50 text-red-700 ring-red-200',
  rejected:  'bg-red-50 text-red-700 ring-red-200',
  upcoming:  'bg-slate-50 text-slate-600 ring-slate-200',
  cancelled: 'bg-slate-50 text-slate-400 ring-slate-200 line-through',
  na:        'bg-slate-50 text-slate-400 ring-slate-200',
}

const LABELS = {
  paid: 'Paid',
  approved: 'Approved',
  pending: 'Pending',
  overdue: 'Overdue',
  rejected: 'Rejected',
  upcoming: 'Not due',
  cancelled: 'Cancelled',
  na: 'N/A',
}

export default function Badge({ status }) {
  const { t } = useLanguage()
  const key = String(status || 'na').toLowerCase()
  return (
    <span
      className={`inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium leading-5 ring-1 ring-inset ${
        STYLES[key] || STYLES.na
      }`}
    >
      {LABELS[key] ? t(LABELS[key]) : status}
    </span>
  )
}
