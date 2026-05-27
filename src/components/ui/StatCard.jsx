// Summary metric card (build plan §9). `danger` highlights a non-zero amount due.
export default function StatCard({ label, value, sub, danger = false }) {
  return (
    <div
      className={`rounded-2xl border p-4 ${
        danger ? 'border-red-200 bg-red-50' : 'border-gray-100 bg-white'
      }`}
    >
      <p className="text-xs text-gray-500">{label}</p>
      <p className={`mt-1 text-lg font-semibold ${danger ? 'text-red-700' : 'text-gray-900'}`}>
        {value}
      </p>
      {sub && <p className="mt-0.5 text-xs text-gray-400">{sub}</p>}
    </div>
  )
}
