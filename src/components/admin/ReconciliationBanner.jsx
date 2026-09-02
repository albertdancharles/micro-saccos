// Books-don't-balance warning (migration 027).
//
// Deliberately silent when everything is fine. The group's pool is computed from a
// ten-term expression over eight tables; this compares it against the same worth
// derived independently (member capital + retained earnings) and only speaks up if
// the two disagree. A dashboard badge saying "balanced ✓" every day would train
// admins to ignore it — which is exactly what you don't want on the one day it
// says something else.
import { formatTZS } from '../../lib/format'
import { useLanguage } from '../../hooks/useLanguage'

export default function ReconciliationBanner({ reconciliation }) {
  const { t } = useLanguage()

  // No row = migration 027 not applied yet. Nothing to say.
  if (!reconciliation || reconciliation.balanced) return null

  const diff = Number(reconciliation.difference_tzs)

  return (
    <section
      role="alert"
      className="rounded-2xl border border-red-300 bg-red-50 p-4 sm:p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]"
    >
      <h2 className="text-[13px] font-semibold tracking-tight text-red-800">
        {t('The group’s books do not balance')}
      </h2>
      <p className="mt-1 text-sm text-red-700">
        {t('What the group holds and what members are owed differ by {amount}. Do not close a cycle or pay anything out until this is resolved.')
          .replace('{amount}', formatTZS(Math.abs(diff)))}
      </p>

      <dl className="mt-3 space-y-1 text-xs">
        <Row label={t('Pool')} value={reconciliation.pool_tzs} />
        <Row label={t('Out on loans')} value={reconciliation.outstanding_tzs} />
        <Row label={t('Total held')} value={reconciliation.total_assets_tzs} strong />
        <div className="h-1" />
        <Row label={t('Member capital')} value={reconciliation.member_capital_tzs} />
        <Row label={t('Retained earnings')} value={reconciliation.retained_earnings_tzs} />
        <Row label={t('Admin adjustments')} value={reconciliation.pool_adjustments_tzs} />
        <Row label={t('Total owed')} value={reconciliation.total_claims_tzs} strong />
        <div className="h-1" />
        <Row label={t('Difference')} value={diff} strong danger />
      </dl>
    </section>
  )
}

function Row({ label, value, strong, danger }) {
  return (
    <div className="flex justify-between">
      <dt className={danger ? 'text-red-700' : 'text-red-600/80'}>{label}</dt>
      <dd
        className={`tabular-nums ${danger ? 'text-red-800' : 'text-red-700'} ${
          strong ? 'font-semibold' : ''
        }`}
      >
        {formatTZS(value)}
      </dd>
    </div>
  )
}
