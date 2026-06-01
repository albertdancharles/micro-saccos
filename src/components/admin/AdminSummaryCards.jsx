// Admin summary cards (build plan §9). Total group assets headline, then pool,
// fees collected this month (X/N), active loans, and pending reviews
// (danger-styled when there's a backlog).
import StatCard from '../ui/StatCard'
import { formatTZS } from '../../lib/format'

export default function AdminSummaryCards({ stats }) {
  const outstanding = Number(stats.outstandingLoans ?? 0)
  const total = Number(stats.totalAssets ?? stats.pool)
  return (
    <div className="space-y-3">
      <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4">
        <p className="text-xs text-sky-700">Total group assets</p>
        <p className="mt-1 text-2xl font-semibold text-sky-900">{formatTZS(total)}</p>
        <p className="mt-1 text-xs text-sky-700/80">
          {formatTZS(stats.pool)} in the pool · {formatTZS(outstanding)} out on loans
        </p>
      </div>
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
    </div>
  )
}
