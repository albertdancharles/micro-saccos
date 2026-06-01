// Status badge (build plan §9). Covers obligation statuses (paid/pending/overdue/
// upcoming/na) and submission statuses (approved/pending/rejected).
const STYLES = {
  paid: 'bg-emerald-100 text-emerald-700',
  approved: 'bg-emerald-100 text-emerald-700',
  pending: 'bg-amber-100 text-amber-700',
  overdue: 'bg-red-100 text-red-700',
  rejected: 'bg-red-100 text-red-700',
  upcoming: 'bg-gray-100 text-gray-500',
  cancelled: 'bg-gray-100 text-gray-400 line-through',
  na: 'bg-gray-100 text-gray-400',
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
  const key = String(status || 'na').toLowerCase()
  return (
    <span
      className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${
        STYLES[key] || STYLES.na
      }`}
    >
      {LABELS[key] || status}
    </span>
  )
}
