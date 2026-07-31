// Member dashboard (build plan §9, item 23). Calls ensure_current_fees() on mount
// (self-healing fee generation, §8c-bis) then loads the summary and renders the
// member flows. A "Log transaction" sheet feeds new proofs into the approvals queue.
import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { useMemberSummary } from '../hooks/useMemberSummary'
import { signOut } from '../lib/auth'
import { supabase } from '../supabaseClient'
import SummaryCards from '../components/member/SummaryCards'
import ObligationsCard from '../components/member/ObligationsCard'
import RepaymentSchedule from '../components/member/RepaymentSchedule'
import LoanRequestForm from '../components/member/LoanRequestForm'
import LogTransactionSheet from '../components/member/LogTransactionSheet'
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
  const { refresh } = summary
  const [sheetOpen, setSheetOpen] = useState(false)
  const [version, setVersion] = useState(0) // bumps to refetch history after a submit

  // Self-healing fee generation runs only when a member views their own
  // dashboard — in view mode an admin is just looking, no side effects.
  useEffect(() => {
    if (!supabase || isView) return
    supabase.rpc('ensure_current_fees').then(({ error }) => {
      if (error) console.error('ensure_current_fees failed', error)
      refresh()
    })
  }, [isView, refresh])

  function handleSubmitted() {
    refresh()
    setVersion((v) => v + 1)
  }

  async function handleSignOut() {
    await signOut()
    navigate('/login', { replace: true })
  }

  // Hide items the member already has a pending submission for (the server
  // trigger also blocks duplicates, but filtering keeps the UI clean), and
  // exclude cancelled installments (loan closed early — historical only).
  const pending = summary.pendingRelatedIds || new Set()
  const unpaidFees = summary.fees.filter(
    (f) => f.computed_status !== 'paid' && !pending.has(f.id),
  )
  const payableInstallments = summary.installments.filter(
    (i) =>
      i.computed_status !== 'paid' &&
      i.computed_status !== 'cancelled' &&
      !pending.has(i.id),
  )

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
        {!isView && (
          <button onClick={() => setSheetOpen(true)} className="btn-primary w-full !min-h-12">
            {t('+ Log a transaction')}
          </button>
        )}
        {isView && (
          <div className="rounded-xl border border-sky-200/70 bg-sky-50/80 p-3 text-sm text-sky-800">
            {t("Read-only view. Submitting payments, requesting loans, and editing on this member's behalf are disabled. Use the savings edit / approvals queue on the admin dashboard to act.")}
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
            {!isView && (
              <LoanRequestForm
                memberId={user?.id}
                contribution={summary.contribution}
                pool={summary.pool}
                loan={summary.loan}
                onSubmitted={handleSubmitted}
              />
            )}
            <History refreshKey={version} memberId={viewAs} />
          </>
        )}
      </main>

      {!isView && (
        <>
          <LogTransactionSheet
            open={sheetOpen}
            onClose={() => setSheetOpen(false)}
            memberId={user?.id}
            unpaidFees={unpaidFees}
            payableInstallments={payableInstallments}
            onSubmitted={handleSubmitted}
          />
          {/* Omitted in view mode: an admin inspecting a member is in a
              read-only detour and leaves via the header's back control, not by
              switching tabs. */}
          <BottomNav isAdmin={profile?.role === 'admin'} />
        </>
      )}
    </div>
  )
}
