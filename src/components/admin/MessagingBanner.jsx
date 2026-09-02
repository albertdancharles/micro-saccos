// Reminders-not-being-delivered warning (migration 032).
//
// Same posture as ReconciliationBanner: silent when it's working. It exists
// because of how this broke the first time — the daily sweep ran perfectly for
// weeks, wrote its "10 reminders" audit row every morning, and every one of those
// reminders sat in a queue nothing was draining. The job looked healthy from every
// angle an admin could see. A filling queue is the one signal that would have
// said otherwise.
import { useLanguage } from '../../hooks/useLanguage'

export default function MessagingBanner({ messaging }) {
  const { t } = useLanguage()

  // No row = migration 032 not applied yet. Nothing to say.
  if (!messaging) return null

  const stuck = Number(messaging.stuck || 0)
  const failed = Number(messaging.failed_7d || 0)

  // Queued-but-fresh is normal: the drain runs every 15 minutes.
  if (!stuck && !failed) return null

  const lastError = messaging.last_error || ''
  // Beem reports an empty account as code 102. It is the most likely reason for a
  // queue that suddenly stops moving, and it has an obvious fix worth naming.
  const outOfCredit = /balance/i.test(lastError)

  return (
    <section
      role="alert"
      className="rounded-2xl border border-amber-300 bg-amber-50 p-4 sm:p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]"
    >
      <h2 className="text-[13px] font-semibold tracking-tight text-amber-900">
        {stuck
          ? t('Reminders are not reaching members')
          : t('Some reminders could not be delivered')}
      </h2>

      {stuck > 0 && (
        <p className="mt-1 text-sm text-amber-800">
          {t('{n} message(s) have been waiting more than two hours. Members are not being reminded.')
            .replace('{n}', stuck)}
        </p>
      )}

      {failed > 0 && (
        <p className="mt-1 text-sm text-amber-800">
          {t('{n} message(s) failed in the last 7 days.').replace('{n}', failed)}
        </p>
      )}

      {outOfCredit && (
        <p className="mt-2 text-sm font-medium text-amber-900">
          {t('The SMS account is out of credit. Top it up and the queue will clear itself.')}
        </p>
      )}

      {lastError && !outOfCredit && (
        <p className="mt-2 text-xs text-amber-700 break-words">
          {t('Last error')}: {lastError}
        </p>
      )}

      <p className="mt-2 text-xs text-amber-700">
        {t('Nothing is lost — members still see everything in the app.')}
      </p>
    </section>
  )
}
