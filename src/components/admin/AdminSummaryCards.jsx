// Admin summary cards (build plan §9). Pool, fees collected this month (X/N),
// active loans, and pending reviews (danger-styled when there's a backlog).
import StatCard from '../ui/StatCard'
import { formatTZS } from '../../lib/format'

export default function AdminSummaryCards({ stats }) {
  return (
    <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
      <StatCard label="Group pool" value={formatTZS(stats.pool)} />
      <StatCard label="Fees this month" value={`${stats.feesPaid} / ${stats.feesTotal}`} />
      <StatCard label="Active loans" value={stats.activeLoans} />
      <StatCard
        label="Pending reviews"
        value={stats.pendingReviews}
        danger={stats.pendingReviews > 0}
      />
    </div>
  )
}
