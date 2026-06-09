// Admin summary cards (build plan §9). Hero card for total group assets, then
// a 4-tile row of operational stats below. Mirrors the member dashboard
// hierarchy so admins navigating between roles feel consistency.
import StatCard from '../ui/StatCard'
import { formatTZS } from '../../lib/format'

export default function AdminSummaryCards({ stats }) {
  const outstanding = Number(stats.outstandingLoans ?? 0)
  const total = Number(stats.totalAssets ?? stats.pool)

  return (
    <div className="space-y-3">
      <div className="relative overflow-hidden rounded-2xl bg-gradient-to-br from-sky-50 to-white p-5 ring-1 ring-sky-200/70 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_8px_24px_-16px_rgba(15,23,42,0.10)]">
        <p className="text-[11px] font-semibold uppercase tracking-wide text-sky-700">
          Total group assets
        </p>
        <p className="mt-1 text-[28px] font-semibold leading-tight tabular-nums text-sky-900">
          {formatTZS(total)}
        </p>
        <p className="mt-1.5 text-xs text-sky-700/75">
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
