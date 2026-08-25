// Member dashboard — read-only since the admin mandate (migration 034).
//
// This used to be where a member filed things: a "Log a transaction" sheet, a loan
// request form, a withdrawal card, guarantee responses. All of it is gone; admins
// record every transaction now, and the database enforces that (the member INSERT
// policies on loans and payment_submissions were dropped, so a member cannot write
// even by calling PostgREST directly).
//
// What is left is an account statement: what you have saved, what you owe, what has
// been recorded against your name, and the CSV to take away. The one thing worth
// noticing in the diff is that this file no longer branches on `isView`. An admin
// inspecting a member used to get a stripped-down read-only detour through the same
// component; now every member gets exactly that view, so the two cases converged
// and the flag only picks the header and the nav.
import { useNavigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { useMemberSummary } from '../hooks/useMemberSummary'
import { signOut } from '../lib/auth'
import SummaryCards from '../components/member/SummaryCards'
import ObligationsCard from '../components/member/ObligationsCard'
import RepaymentSchedule from '../components/member/RepaymentSchedule'
import History from '../components/member/History'
import LoanProgressBar from '../components/member/LoanProgressBar'
import AppHeader from '../components/ui/AppHeader'
import BottomNav from '../components/ui/BottomNav'
import SavingsChart from '../components/member/SavingsChart'

export default function MemberDashboard({ viewAs = null, viewedName = null }) {
  const { profile, user } = useAuth()
  const { t } = useLanguage()
  const navigate = useNavigate()
  const isView = !!viewAs
  const summary = useMemberSummary(viewAs)
  // ensure_current_fees() used to fire here on every member's mount. It is a
  // WRITE — it generates the month's fee rows for the whole group — so a member
  // loading their dashboard was writing to the database. It now runs only from the
  // admin dashboard, with migration 017's pg_cron job as the real generator so fee
  // creation does not depend on anyone opening the app.

  async function handleSignOut() {
    await signOut()
    navigate('/login', { replace: true })
  }

  return (
    <div className="min-h-dvh bg-[var(--color-app-bg)]">
      {isView ? (
        <AppHeader
          eyebrow={t('Viewing as admin')}
          title={viewedName || 'Member'}
          back={{ to: '/admin', label: t('← Admin') }}
          showControls={false}
        />
      ) : (
        <AppHeader
          eyebrow={t('Micro-SACCOS')}
          title={profile?.full_name || user?.email}
          links={[
            { to: '/members', label: t('Members') },
            { to: '/profile', label: t('Profile') },
          ]}
          onSignOut={handleSignOut}
        />
      )}

      <main className="max-w-md mx-auto px-4 sm:px-6 py-5 sm:py-6 space-y-4 pb-nav">
        {isView && (
          <div className="rounded-xl border border-sky-200/70 bg-sky-50/80 p-3 text-sm text-sky-800">
            {t('Read-only view. Use the admin dashboard to record a payment, file a loan, or correct an entry for this member.')}
          </div>
        )}

        {summary.error && (
          <div className="rounded-xl border border-red-200/70 bg-red-50 p-3 text-sm text-red-700">
            {summary.error}
          </div>
        )}

        {summary.loading ? (
          <p className="text-center text-slate-400 py-8">{t('Loading dashboard…')}</p>
        ) : (
          <>
            <SummaryCards
              pool={summary.pool}
              outstandingLoans={summary.outstandingLoans}
              totalAssets={summary.totalAssets}
              savings={summary.savings}
              contribution={summary.contribution}
              loan={summary.loan}
              amountDue={summary.amountDue}
              penaltyDue={summary.penaltyDue}
            />
            <ObligationsCard
              fees={summary.fees}
              installments={summary.installments}
              currentMonthKey={summary.currentMonthKey}
            />
            <LoanProgressBar loan={summary.loan} installments={summary.installments} />
            <RepaymentSchedule
              installments={summary.installments}
              currentMonthKey={summary.currentMonthKey}
            />
            <SavingsChart memberId={viewAs} />
            <History memberId={viewAs} />
            {!isView && (
              <p className="px-1 pb-2 text-center text-xs leading-relaxed text-slate-500">
                {t('Payments are recorded by your admin. Speak to them to pay in, request a loan, or withdraw.')}
              </p>
            )}
          </>
        )}
      </main>

      {/* Omitted in view mode: an admin inspecting a member is in a read-only
          detour and leaves via the header's back control, not by switching tabs. */}
      {!isView && <BottomNav isAdmin={profile?.role === 'admin'} />}
    </div>
  )
}
