// Summary metric card (build plan §9). Soft elevation + subtle inner highlight
// (UI/UX Pro Max §4 elevation-consistent), tabular-nums so realtime amount
// changes don't shift digit columns, optional `danger` and `accent` variants.
export default function StatCard({ label, value, sub, danger = false, accent = false }) {
  const tone = danger
    ? 'border-red-200 bg-red-50/70'
    : accent
      ? 'border-emerald-200 bg-emerald-50/70'
      : 'border-slate-200/70 bg-white'

  const valueColor = danger
    ? 'text-red-700'
    : accent
      ? 'text-emerald-800'
      : 'text-slate-900'

  return (
    <div
      className={`rounded-2xl border p-4 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)] transition-shadow hover:shadow-[0_6px_14px_-8px_rgba(15,23,42,0.10)] ${tone}`}
    >
      <p className="text-[11px] font-medium uppercase tracking-wide text-slate-500">{label}</p>
      <p className={`mt-1 text-xl font-semibold tabular-nums ${valueColor}`}>{value}</p>
      {sub && <p className="mt-0.5 text-xs text-slate-400">{sub}</p>}
    </div>
  )
}
