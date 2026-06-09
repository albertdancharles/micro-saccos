// Member status grid (build plan §9). One row per active member (admin included).
// Monthly fee + this-month loan interest with badges + penalty; whole row tints
// red when anything is overdue. Scrolls horizontally on small screens (§13).
// UI/UX Pro Max: refined column type, tabular nums, hover-row affordance,
// segmented action links so it scans cleanly even at narrow widths.
import { Link } from 'react-router-dom'
import Badge from '../ui/Badge'
import { formatTZS } from '../../lib/format'

function FeeCell({ fee }) {
  if (!fee) return <Badge status="na" />
  return (
    <div className="flex flex-col items-start gap-1">
      <Badge status={fee.computed_status} />
      {Number(fee.penalty_due) > 0 && (
        <span className="text-[11px] text-red-600 tabular-nums">
          +{formatTZS(fee.penalty_due)}
        </span>
      )}
    </div>
  )
}

function InterestCell({ installment }) {
  if (!installment) return <Badge status="na" />
  return (
    <div className="flex flex-col items-start gap-1">
      <Badge status={installment.computed_status} />
      <span className="text-[11px] text-slate-500 tabular-nums">
        {formatTZS(installment.total_with_penalty)}
      </span>
    </div>
  )
}

export default function MemberGrid({
  rows,
  currentAdminId,
  onRequestDelete,
  onRequestEditSavings,
  onRequestRoleChange,
}) {
  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <div className="flex items-baseline justify-between mb-3">
        <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">Members</h2>
        <span className="text-xs text-slate-400 tabular-nums">{rows.length} total</span>
      </div>
      <div className="overflow-x-auto -mx-5 px-5">
        <table className="w-full text-sm min-w-[34rem]">
          <thead>
            <tr className="text-left text-[11px] uppercase tracking-wide text-slate-400">
              <th className="py-2 pr-3 font-semibold">#</th>
              <th className="py-2 pr-3 font-semibold">Member</th>
              <th className="py-2 pr-3 font-semibold">Monthly fee</th>
              <th className="py-2 pr-3 font-semibold">Loan interest</th>
              <th className="py-2 pr-3 font-semibold">Overall</th>
              <th className="py-2 font-semibold text-right pr-1" aria-label="Actions">
                Actions
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, idx) => {
              const isSelf = currentAdminId === r.id
              return (
                <tr
                  key={r.id}
                  className={`border-t border-slate-100 transition-colors ${
                    r.overall === 'overdue'
                      ? 'bg-red-50/60 hover:bg-red-50'
                      : 'hover:bg-slate-50/70'
                  }`}
                >
                  <td className="py-3 pr-3 text-slate-400 tabular-nums">{idx + 1}</td>
                  <td className="py-3 pr-3 whitespace-nowrap">
                    <span className="font-medium text-slate-900">{r.name}</span>
                    {r.role === 'admin' && (
                      <span className="ml-1.5 inline-flex items-center rounded-full bg-slate-100 px-1.5 py-0.5 text-[10px] font-medium text-slate-600 ring-1 ring-inset ring-slate-200">
                        admin
                      </span>
                    )}
                  </td>
                  <td className="py-3 pr-3">
                    <FeeCell fee={r.fee} />
                  </td>
                  <td className="py-3 pr-3">
                    <InterestCell installment={r.installment} />
                  </td>
                  <td className="py-3 pr-3">
                    <Badge status={r.overall} />
                  </td>
                  <td className="py-3 text-right whitespace-nowrap">
                    <div className="inline-flex items-center gap-3">
                      {(r.role !== 'admin' || isSelf) && (
                        <Link
                          to={`/admin/member/${r.id}`}
                          className="text-xs font-medium text-sky-700 hover:text-sky-800 hover:underline underline-offset-2"
                        >
                          View
                        </Link>
                      )}
                      {(r.role !== 'admin' || isSelf) && (
                        <button
                          onClick={() => onRequestEditSavings?.(r)}
                          className="text-xs font-medium text-emerald-700 hover:text-emerald-800 hover:underline underline-offset-2"
                        >
                          Edit savings
                        </button>
                      )}
                      {!isSelf && (
                        <button
                          onClick={() => onRequestRoleChange?.(r)}
                          className="text-xs font-medium text-amber-700 hover:text-amber-800 hover:underline underline-offset-2"
                        >
                          {r.role === 'admin' ? 'Revoke admin' : 'Make admin'}
                        </button>
                      )}
                      {!isSelf && (
                        <button
                          onClick={() => onRequestDelete?.(r)}
                          className="text-xs font-medium text-red-600 hover:text-red-700 hover:underline underline-offset-2"
                        >
                          Delete
                        </button>
                      )}
                    </div>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </section>
  )
}
