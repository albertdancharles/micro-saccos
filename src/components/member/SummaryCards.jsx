// Member summary cards (build plan §9). Refined hero card for "Total group
// assets" — soft sky tint, generous numeric type, clear breakdown — followed
// by the 2x2 grid of StatCards and an emerald-accented "Max loan" card.
// Honors UI/UX Pro Max §6 typography (tabular nums), §5 layout, §4 elevation.
import StatCard from '../ui/StatCard'
import { formatTZS } from '../../lib/format'
import { contributionCeiling, poolCeiling, maxLoan } from '../../lib/loanMath'

function HeroCard({ label, value, sub, tone = 'sky' }) {
  const palette =
    tone === 'sky'
      ? {
          ring: 'ring-sky-200/70',
          bg: 'from-sky-50 to-white',
          chip: 'text-sky-700',
          text: 'text-sky-900',
          sub: 'text-sky-700/75',
        }
      : {
          ring: 'ring-emerald-200/70',
          bg: 'from-emerald-50 to-white',
          chip: 'text-emerald-700',
          text: 'text-emerald-900',
          sub: 'text-emerald-700/75',
        }

  return (
    <div
      className={`relative col-span-2 overflow-hidden rounded-2xl bg-gradient-to-br ${palette.bg} p-5 ring-1 ${palette.ring} shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_8px_24px_-16px_rgba(15,23,42,0.10)]`}
    >
      <p className={`text-[11px] font-semibold uppercase tracking-wide ${palette.chip}`}>
        {label}
      </p>
      <p className={`mt-1 text-[28px] font-semibold leading-tight tabular-nums ${palette.text}`}>
        {value}
      </p>
      {sub && <p className={`mt-1.5 text-xs ${palette.sub}`}>{sub}</p>}
    </div>
  )
}

export default function SummaryCards({
  pool,
  outstandingLoans = 0,
  totalAssets = 0,
  savings,
  contribution,
  loan,
  amountDue,
  penaltyDue,
}) {
  const loanBalance =
    loan?.status === 'active'
      ? Number(loan.outstanding_principal ?? loan.principal)
      : 0
  const originalPrincipal = loan?.status === 'active' ? Number(loan.principal) : 0
  const principalRepaid = Math.max(0, originalPrincipal - loanBalance)

  const contribCap = contributionCeiling(contribution)
  const poolCap = poolCeiling(pool)
  const maxLoanAmount = maxLoan(contribution, pool)
  const hasOpenLoan = loan?.status === 'pending' || loan?.status === 'active'

  const bindingNote =
    maxLoanAmount === 0
      ? contribCap === 0
        ? 'Make a savings deposit or pay your monthly fee to become eligible.'
        : 'Group pool is currently too low to issue a loan.'
      : contribCap < poolCap
        ? 'Limited by 3× your savings.'
        : contribCap === poolCap
          ? 'Both rules cap at the same amount.'
          : 'Limited by 25% of the group pool.'

  return (
    <div className="grid grid-cols-2 gap-3">
      <HeroCard
        label="Total group assets"
        value={formatTZS(totalAssets)}
        sub={`${formatTZS(pool)} in the pool · ${formatTZS(outstandingLoans)} out on loans`}
        tone="sky"
      />

      <StatCard label="Group pool" value={formatTZS(pool)} />
      <StatCard label="My savings" value={formatTZS(savings)} />
      <StatCard
        label="My loan balance"
        value={formatTZS(loanBalance)}
        sub={
          loan?.status === 'pending'
            ? 'Request pending'
            : principalRepaid > 0
              ? `Repaid ${formatTZS(principalRepaid)} of ${formatTZS(originalPrincipal)}`
              : undefined
        }
      />
      <StatCard
        label="Amount due"
        value={formatTZS(amountDue)}
        danger={amountDue > 0}
        sub={penaltyDue > 0 ? `Incl. ${formatTZS(penaltyDue)} penalty` : undefined}
      />

      <HeroCard
        label="Max loan you can request"
        value={formatTZS(maxLoanAmount)}
        sub={`${bindingNote}${hasOpenLoan && maxLoanAmount > 0 ? ' Available once your current loan is closed.' : ''}`}
        tone="emerald"
      />
    </div>
  )
}
