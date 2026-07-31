// Member status grid (build plan §9). One row per active member (admin included).
// Monthly fee + this-month loan interest with status + penalty; the row tints red
// when anything is overdue.
//
// Two presentations of the same data: a card list below 768px and a table above
// it. The table needed ~544px, so on every phone it scrolled sideways — an admin
// had to swipe right to see status, then keep swiping to reach the actions. The
// card list puts each member's status and actions in one glance-able block.
//
// Visual pass: every row used to carry three pills of the same word (fee,
// interest, overall) plus an "N/A" pill for anyone without a loan, and four
// text links in four different colours. Seven members meant ~28 pills and ~28
// coloured words all competing with each other, so nothing read as urgent.
// Now:
//   - fee and interest are a quiet dot + label, and "—" replaces the N/A pill;
//   - only the overall status keeps a pill, so colour means "look here" again;
//   - the four actions collapse into one overflow menu per row, which also ends
//     the ragged right edge caused by rows having different action sets;
//   - a monogram anchors each row for scanning and carries the admin marker, so
//     the role chip is gone.
import { Link } from 'react-router-dom'
import Badge, { StatusDot } from '../ui/Badge'
import ActionMenu from '../ui/ActionMenu'
import { formatTZS } from '../../lib/format'
import { statusLabel } from '../../lib/status'
import { useLanguage } from '../../hooks/useLanguage'

// "judas ntandu" -> "JN". First + last initial: middle names are inconsistently
// recorded in this group, so using them would make the same person look
// different from one screen to the next.
function initials(name) {
  const parts = String(name || '').trim().split(/\s+/).filter(Boolean)
  if (!parts.length) return '?'
  const last = parts.length > 1 ? parts[parts.length - 1][0] : ''
  return (parts[0][0] + last).toUpperCase()
}

function Monogram({ name, isAdmin }) {
  return (
    <span
      aria-hidden="true"
      className={`grid size-9 shrink-0 place-items-center rounded-full text-[11px] font-semibold ${
        isAdmin
          ? 'bg-emerald-50 text-emerald-700 ring-1 ring-inset ring-emerald-100'
          : 'bg-slate-100 text-slate-500'
      }`}
    >
      {initials(name)}
    </span>
  )
}

// Name + role, shared by both presentations. The name links to the member's
// detail view wherever that view is permitted; where it isn't (another admin's
// row) it stays plain text rather than a link that would only 403.
function MemberIdentity({ row, isSelf, viewTo, t }) {
  const caption = [row.role === 'admin' ? t('Admin') : null, isSelf ? t('You') : null]
    .filter(Boolean)
    .join(' · ')

  return (
    <div className="flex min-w-0 items-center gap-3">
      <Monogram name={row.name} isAdmin={row.role === 'admin'} />
      <div className="min-w-0">
        {viewTo ? (
          <Link
            to={viewTo}
            className="block truncate text-[15px] font-medium text-slate-900 transition-colors hover:text-emerald-700"
          >
            {row.name}
          </Link>
        ) : (
          <span className="block truncate text-[15px] font-medium text-slate-900">{row.name}</span>
        )}
        {caption && (
          <p className="truncate text-[11px] font-medium text-slate-400">{caption}</p>
        )}
      </div>
    </div>
  )
}

// One obligation (monthly fee or this month's loan interest): status in words,
// with the money underneath only when there is money to show. A member with no
// loan gets a dash — an "N/A" pill in every row of the interest column was the
// single noisiest thing on the screen and carried no information.
function Obligation({ status, amount, amountTone = 'text-slate-500', t }) {
  if (!status) return <span className="text-slate-300">—</span>
  const label = statusLabel(status)
  return (
    <div>
      <div className="flex items-center gap-2">
        <StatusDot status={status} />
        <span className="text-[13px] text-slate-600">{label ? t(label) : status}</span>
      </div>
      {amount && (
        <p className={`mt-0.5 pl-[14px] text-[11px] tabular-nums ${amountTone}`}>{amount}</p>
      )}
    </div>
  )
}

function FeeCell({ fee, t }) {
  return (
    <Obligation
      status={fee?.computed_status}
      amount={Number(fee?.penalty_due) > 0 ? `+${formatTZS(fee.penalty_due)}` : null}
      amountTone="text-red-600"
      t={t}
    />
  )
}

function InterestCell({ installment, t }) {
  return (
    <Obligation
      status={installment?.computed_status}
      amount={installment ? formatTZS(installment.total_with_penalty) : null}
      t={t}
    />
  )
}

// The same action set feeds both presentations, so the two can't drift apart.
// Plain function, not a hook — it holds no state and is called per row.
// `tone` is semantic ('danger'), not a class: the menu owns how that looks.
function buildActions({
  row,
  isSelf,
  onRequestEditSavings,
  onRequestRoleChange,
  onRequestDelete,
  onRequestExit,
  t,
}) {
  const actions = []
  if (row.role !== 'admin' || isSelf) {
    actions.push({ key: 'view', to: `/admin/member/${row.id}`, label: t('View') })
    actions.push({ key: 'savings', onClick: () => onRequestEditSavings?.(row), label: t('Edit savings') })
  }
  if (!isSelf) {
    actions.push({
      key: 'role',
      onClick: () => onRequestRoleChange?.(row),
      label: row.role === 'admin' ? t('Revoke admin') : t('Make admin'),
    })
    // Exit settles the member and deactivates them, KEEPING their history — it sits
    // above Delete because it is almost always the right choice for someone who is
    // simply leaving. Delete still erases everything, and stays last.
    actions.push({
      key: 'exit',
      onClick: () => onRequestExit?.(row),
      label: t('Settle & exit'),
    })
    actions.push({
      key: 'delete',
      onClick: () => onRequestDelete?.(row),
      label: t('Delete'),
      tone: 'danger',
    })
  }
  return actions
}

function MemberCard({ row, isSelf, viewTo, actions, t }) {
  return (
    <li
      className={`-mx-5 border-t border-slate-100 px-5 py-3.5 first:border-t-0 ${
        row.overall === 'overdue' ? 'bg-red-50/50' : ''
      }`}
    >
      <div className="flex items-center justify-between gap-2">
        <MemberIdentity row={row} isSelf={isSelf} viewTo={viewTo} t={t} />
        <div className="flex shrink-0 items-center gap-1">
          <Badge status={row.overall} />
          <ActionMenu
            actions={actions}
            label={t('Actions for {name}').replace('{name}', row.name)}
          />
        </div>
      </div>

      <div className="mt-2 grid grid-cols-2 gap-3 rounded-xl bg-slate-50/70 px-3 py-2.5">
        <div>
          <p className="mb-1 text-[10px] font-medium uppercase tracking-wide text-slate-400">
            {t('Monthly fee')}
          </p>
          <FeeCell fee={row.fee} t={t} />
        </div>
        <div>
          <p className="mb-1 text-[10px] font-medium uppercase tracking-wide text-slate-400">
            {t('Loan interest')}
          </p>
          <InterestCell installment={row.installment} t={t} />
        </div>
      </div>
    </li>
  )
}

function MemberRow({ row, isSelf, viewTo, actions, t }) {
  return (
    <tr
      className={`transition-colors ${
        row.overall === 'overdue' ? 'bg-red-50/50 hover:bg-red-50' : 'hover:bg-slate-50/70'
      }`}
    >
      <td className="py-2.5 pr-3">
        <MemberIdentity row={row} isSelf={isSelf} viewTo={viewTo} t={t} />
      </td>
      <td className="py-2.5 pr-3">
        <FeeCell fee={row.fee} t={t} />
      </td>
      <td className="py-2.5 pr-3">
        <InterestCell installment={row.installment} t={t} />
      </td>
      <td className="py-2.5 pr-3">
        <Badge status={row.overall} />
      </td>
      <td className="py-1 pl-3 text-right">
        <ActionMenu
          actions={actions}
          label={t('Actions for {name}').replace('{name}', row.name)}
        />
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
  onRequestExit,
}) {
  const { t } = useLanguage()

  const prepared = rows.map((row) => {
    const isSelf = currentAdminId === row.id
    const actions = buildActions({
      row,
      isSelf,
      onRequestEditSavings,
      onRequestRoleChange,
      onRequestDelete,
      onRequestExit,
      t,
    })
    return {
      row,
      isSelf,
      actions,
      // The name is only a link where the action list grants that view.
      viewTo: actions.find((a) => a.key === 'view')?.to || null,
    }
  })

  const overdue = rows.filter((r) => r.overall === 'overdue').length

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-5 shadow-card">
      <div className="mb-3 flex items-center justify-between gap-3">
        <div className="flex items-baseline gap-2">
          <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">{t('Members')}</h2>
          <span className="text-xs text-slate-400 tabular-nums">
            {t('{n} total').replace('{n}', rows.length)}
          </span>
        </div>
        {/* The one number an admin opens this card to find. */}
        {overdue > 0 && (
          <span className="inline-flex items-center gap-2 rounded-full bg-red-50 px-2.5 py-1 text-[11px] font-medium text-red-700 ring-1 ring-inset ring-red-100 tabular-nums">
            <StatusDot status="overdue" />
            {t('{n} overdue').replace('{n}', overdue)}
          </span>
        )}
      </div>

      {rows.length === 0 ? (
        <p className="py-8 text-center text-sm text-slate-400">{t('No members yet.')}</p>
      ) : (
        <>
          {/* Mobile: one card per member, no horizontal scroll. */}
          <ul className="md:hidden">
            {prepared.map(({ row, isSelf, viewTo, actions }) => (
              <MemberCard
                key={row.id}
                row={row}
                isSelf={isSelf}
                viewTo={viewTo}
                actions={actions}
                t={t}
              />
            ))}
          </ul>

          {/* Desktop: the table, which has room to breathe here. */}
          <div className="hidden md:block">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-slate-100 text-left text-[10px] uppercase tracking-wider text-slate-400">
                  <th className="pb-2 pr-3 font-medium">{t('Member')}</th>
                  <th className="pb-2 pr-3 font-medium">{t('Monthly fee')}</th>
                  <th className="pb-2 pr-3 font-medium">{t('Loan interest')}</th>
                  <th className="pb-2 pr-3 font-medium">{t('Overall')}</th>
                  {/* A visible header over a column of menu buttons is clutter,
                      but screen readers still need the column named. */}
                  <th className="pb-2 pl-3">
                    <span className="sr-only">{t('Actions')}</span>
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {prepared.map(({ row, isSelf, viewTo, actions }) => (
                  <MemberRow
                    key={row.id}
                    row={row}
                    isSelf={isSelf}
                    viewTo={viewTo}
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
