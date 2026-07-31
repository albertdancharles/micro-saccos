// Member status grid (build plan §9). One row per active member (admin included).
// Monthly fee + this-month loan interest with badges + penalty; whole row tints
// red when anything is overdue.
//
// Two presentations of the same data: a card list below 768px and the original
// table above it. The table needed ~544px, so on every phone it scrolled
// sideways — an admin had to swipe right to see status, then keep swiping to
// reach four 12px text links stacked in one cell. The card list puts each
// member's status and actions in one glance-able block with 44px targets.
import { Link } from 'react-router-dom'
import Badge from '../ui/Badge'
import { formatTZS } from '../../lib/format'
import { useLanguage } from '../../hooks/useLanguage'

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

function AdminChip({ label }) {
  return (
    <span className="inline-flex shrink-0 items-center rounded-full bg-slate-100 px-1.5 py-0.5 text-[10px] font-medium text-slate-600 ring-1 ring-inset ring-slate-200">
      {label}
    </span>
  )
}

// The same action set feeds both presentations, so the two can't drift apart.
// Plain function, not a hook — it holds no state and is called per row.
function buildActions({ row, isSelf, onRequestEditSavings, onRequestRoleChange, onRequestDelete, t }) {
  const actions = []
  if (row.role !== 'admin' || isSelf) {
    actions.push({
      key: 'view',
      to: `/admin/member/${row.id}`,
      label: t('View'),
      tone: 'text-sky-700 hover:text-sky-800',
    })
    actions.push({
      key: 'savings',
      onClick: () => onRequestEditSavings?.(row),
      label: t('Edit savings'),
      tone: 'text-emerald-700 hover:text-emerald-800',
    })
  }
  if (!isSelf) {
    actions.push({
      key: 'role',
      onClick: () => onRequestRoleChange?.(row),
      label: row.role === 'admin' ? t('Revoke admin') : t('Make admin'),
      tone: 'text-amber-700 hover:text-amber-800',
    })
    actions.push({
      key: 'delete',
      onClick: () => onRequestDelete?.(row),
      label: t('Delete'),
      tone: 'text-red-600 hover:text-red-700',
    })
  }
  return actions
}

function ActionList({ actions, className = '' }) {
  return (
    <div className={className}>
      {actions.map((a) =>
        a.to ? (
          <Link key={a.key} to={a.to} className={`tap-action ${a.tone}`}>
            {a.label}
          </Link>
        ) : (
          <button key={a.key} onClick={a.onClick} className={`tap-action ${a.tone}`}>
            {a.label}
          </button>
        ),
      )}
    </div>
  )
}

function MemberCard({ row, index, actions, t }) {
  return (
    <li
      className={`-mx-5 border-t border-slate-100 px-5 py-4 first:border-t-0 ${
        row.overall === 'overdue' ? 'bg-red-50/60' : ''
      }`}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="flex min-w-0 items-center gap-2">
          <span className="text-xs text-slate-400 tabular-nums">{index + 1}</span>
          <span className="truncate font-medium text-slate-900">{row.name}</span>
          {row.role === 'admin' && <AdminChip label={t('admin')} />}
        </div>
        <Badge status={row.overall} />
      </div>

      <div className="mt-3 grid grid-cols-2 gap-3">
        <div>
          <p className="mb-1 text-[10px] font-medium uppercase tracking-wide text-slate-400">
            {t('Monthly fee')}
          </p>
          <FeeCell fee={row.fee} />
        </div>
        <div>
          <p className="mb-1 text-[10px] font-medium uppercase tracking-wide text-slate-400">
            {t('Loan interest')}
          </p>
          <InterestCell installment={row.installment} />
        </div>
      </div>

      {actions.length > 0 && (
        <ActionList
          actions={actions}
          className="mt-2 flex flex-wrap items-center gap-x-5 gap-y-0 border-t border-slate-100 pt-1"
        />
      )}
    </li>
  )
}

function MemberRow({ row, index, actions, t }) {
  return (
    <tr
      className={`border-t border-slate-100 transition-colors ${
        row.overall === 'overdue' ? 'bg-red-50/60 hover:bg-red-50' : 'hover:bg-slate-50/70'
      }`}
    >
      <td className="py-3 pr-3 text-slate-400 tabular-nums">{index + 1}</td>
      <td className="py-3 pr-3 whitespace-nowrap">
        <span className="font-medium text-slate-900">{row.name}</span>
        {row.role === 'admin' && (
          <span className="ml-1.5">
            <AdminChip label={t('admin')} />
          </span>
        )}
      </td>
      <td className="py-3 pr-3">
        <FeeCell fee={row.fee} />
      </td>
      <td className="py-3 pr-3">
        <InterestCell installment={row.installment} />
      </td>
      <td className="py-3 pr-3">
        <Badge status={row.overall} />
      </td>
      <td className="py-3 text-right whitespace-nowrap">
        <ActionList actions={actions} className="inline-flex items-center gap-5" />
      </td>
    </tr>
  )
}

export default function MemberGrid({
  rows,
  currentAdminId,
  onRequestDelete,
  onRequestEditSavings,
  onRequestRoleChange,
}) {
  const { t } = useLanguage()

  const prepared = rows.map((row) => {
    const isSelf = currentAdminId === row.id
    return {
      row,
      isSelf,
      actions: buildActions({
        row,
        isSelf,
        onRequestEditSavings,
        onRequestRoleChange,
        onRequestDelete,
        t,
      }),
    }
  })

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <div className="mb-3 flex items-baseline justify-between">
        <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">{t('Members')}</h2>
        <span className="text-xs text-slate-400 tabular-nums">
          {t('{n} total').replace('{n}', rows.length)}
        </span>
      </div>

      {rows.length === 0 ? (
        <p className="py-8 text-center text-sm text-slate-400">{t('No members yet.')}</p>
      ) : (
        <>
          {/* Mobile: one card per member, no horizontal scroll. */}
          <ul className="md:hidden">
            {prepared.map(({ row, actions }, idx) => (
              <MemberCard
                key={row.id}
                row={row}
                index={idx}
                actions={actions}
                t={t}
              />
            ))}
          </ul>

          {/* Desktop: the original table, which has room to breathe here. */}
          <div className="hidden md:block">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-[11px] uppercase tracking-wide text-slate-400">
                  <th className="py-2 pr-3 font-semibold">#</th>
                  <th className="py-2 pr-3 font-semibold">{t('Member')}</th>
                  <th className="py-2 pr-3 font-semibold">{t('Monthly fee')}</th>
                  <th className="py-2 pr-3 font-semibold">{t('Loan interest')}</th>
                  <th className="py-2 pr-3 font-semibold">{t('Overall')}</th>
                  <th className="py-2 pr-1 text-right font-semibold">{t('Actions')}</th>
                </tr>
              </thead>
              <tbody>
                {prepared.map(({ row, actions }, idx) => (
                  <MemberRow
                    key={row.id}
                    row={row}
                    index={idx}
                    actions={actions}
                    t={t}
                  />
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </section>
  )
}
