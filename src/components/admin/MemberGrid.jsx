// Member status grid (build plan §9). One row per active member (admin included).
// Monthly fee + this-month loan interest with badges + penalty; whole row turns
// danger when anything is overdue. Scrolls horizontally on small screens (§13).
import Badge from '../ui/Badge'
import { formatTZS } from '../../lib/format'

function FeeCell({ fee }) {
  if (!fee) return <Badge status="na" />
  return (
    <div className="flex flex-col items-start gap-0.5">
      <Badge status={fee.computed_status} />
      {Number(fee.penalty_due) > 0 && (
        <span className="text-xs text-red-600">+{formatTZS(fee.penalty_due)}</span>
      )}
    </div>
  )
}

function InterestCell({ installment }) {
  if (!installment) return <Badge status="na" />
  return (
    <div className="flex flex-col items-start gap-0.5">
      <Badge status={installment.computed_status} />
      <span className="text-xs text-gray-500">{formatTZS(installment.total_with_penalty)}</span>
    </div>
  )
}

export default function MemberGrid({ rows }) {
  return (
    <section className="rounded-2xl border border-gray-100 bg-white p-4">
      <h2 className="text-sm font-semibold text-gray-900 mb-3">Members</h2>
      <div className="overflow-x-auto">
        <table className="w-full text-sm min-w-[28rem]">
          <thead>
            <tr className="text-left text-xs text-gray-400">
              <th className="py-2 pr-3 font-medium">#</th>
              <th className="py-2 pr-3 font-medium">Member</th>
              <th className="py-2 pr-3 font-medium">Monthly fee</th>
              <th className="py-2 pr-3 font-medium">Loan interest</th>
              <th className="py-2 font-medium">Overall</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, idx) => (
              <tr
                key={r.id}
                className={`border-t border-gray-50 ${r.overall === 'overdue' ? 'bg-red-50' : ''}`}
              >
                <td className="py-2 pr-3 text-gray-400">{idx + 1}</td>
                <td className="py-2 pr-3 text-gray-900 whitespace-nowrap">
                  {r.name}
                  {r.role === 'admin' && <span className="ml-1 text-xs text-gray-400">(admin)</span>}
                </td>
                <td className="py-2 pr-3">
                  <FeeCell fee={r.fee} />
                </td>
                <td className="py-2 pr-3">
                  <InterestCell installment={r.installment} />
                </td>
                <td className="py-2">
                  <Badge status={r.overall} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
