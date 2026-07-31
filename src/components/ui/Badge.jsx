// Status badge (build plan §9). Covers obligation statuses (paid/pending/overdue/
// upcoming/cancelled/na) and submission statuses (approved/pending/rejected).
// Uses an inset ring instead of a solid background so badges read as pills on
// any background (cards, table rows, modals) — UI/UX Pro Max §6 semantic color
// + state clarity. Tone-paired text/ring keeps contrast >= 4.5:1.
import { useLanguage } from '../../hooks/useLanguage'
import { statusKey, statusLabel } from '../../lib/status'

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

// Dot rendering of the same statuses, for places that already carry one pill and
// would turn to noise with a second (the member grid's fee / interest columns).
// The halo is a ring rather than extra size, so a dot occupies 6px of layout and
// still reads at a glance.
const DOTS = {
  paid:      'bg-emerald-500 ring-emerald-500/15',
  approved:  'bg-emerald-500 ring-emerald-500/15',
  pending:   'bg-amber-500 ring-amber-500/15',
  overdue:   'bg-red-500 ring-red-500/15',
  rejected:  'bg-red-500 ring-red-500/15',
  upcoming:  'bg-slate-300 ring-slate-300/20',
  cancelled: 'bg-slate-300 ring-slate-300/20',
  na:        'bg-slate-200 ring-slate-200/20',
}

// Decorative by contract: every caller pairs it with the status in words, so
// colour is never the only carrier of meaning.
export function StatusDot({ status, className = '' }) {
  return (
    <span
      aria-hidden="true"
      className={`inline-block size-1.5 shrink-0 rounded-full ring-[3px] ${
        DOTS[statusKey(status)] || DOTS.na
      } ${className}`}
    />
  )
}

export default function Badge({ status }) {
  const { t } = useLanguage()
  const label = statusLabel(status)
  return (
    <span
      className={`inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium leading-5 ring-1 ring-inset ${
        STYLES[statusKey(status)] || STYLES.na
      }`}
    >
      {label ? t(label) : status}
    </span>
  )
}
