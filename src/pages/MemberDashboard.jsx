// Member dashboard (build plan §9, item 23). Calls ensure_current_fees() on mount
// (self-healing fee generation, §8c-bis) then loads the summary and renders the
// member flows. A "Log transaction" sheet feeds new proofs into the approvals queue.
import { useEffect, useState } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useMemberSummary } from '../hooks/useMemberSummary'
import { signOut } from '../lib/auth'
import { supabase } from '../supabaseClient'
import SummaryCards from '../components/member/SummaryCards'
import ObligationsCard from '../components/member/ObligationsCard'
import RepaymentSchedule from '../components/member/RepaymentSchedule'
import LoanRequestForm from '../components/member/LoanRequestForm'
import LogTransactionSheet from '../components/member/LogTransactionSheet'
import History from '../components/member/History'
import SavingsChart from '../components/member/SavingsChart'
import LoanProgressBar from '../components/member/LoanProgressBar'
import NotificationsBell from '../components/ui/NotificationsBell'

export default function MemberDashboard({ viewAs = null, viewedName = null }) {
  const { profile, user } = useAuth()
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
    <div className="min-h-screen bg-gray-50">
      <header className="bg-white border-b border-gray-100 sticky top-0 z-10">
        <div className="max-w-md mx-auto px-6 py-4 flex items-center justify-between">
          <div className="min-w-0">
            <p className="text-xs text-gray-400">
              {isView ? 'Viewing as admin' : 'Micro-SACCOS'}
            </p>
            <h1 className="text-lg font-semibold text-gray-900 truncate">
              {isView ? viewedName || 'Member' : profile?.full_name || user?.email}
            </h1>
          </div>
          <div className="flex items-center gap-4 shrink-0">
            {isView ? (
              <Link to="/admin" className="text-sm text-gray-500 hover:text-gray-700">
                ← Back to admin
              </Link>
            ) : (
              <>
                <NotificationsBell />
                <Link to="/profile" className="text-sm text-gray-500 hover:text-gray-700">
                  Profile
                </Link>
                <button
                  onClick={handleSignOut}
                  className="text-sm text-gray-500 hover:text-gray-700"
                >
                  Sign out
                </button>
              </>
            )}
          </div>
        </div>
      </header>

      <main className="max-w-md mx-auto px-6 py-6 space-y-4">
        {!isView && (
          <button
            onClick={() => setSheetOpen(true)}
            className="w-full rounded-xl bg-emerald-600 text-white font-medium py-3 hover:bg-emerald-700 transition-colors"
          >
            + Log a transaction
          </button>
        )}
        {isView && (
          <div className="rounded-xl border border-sky-200 bg-sky-50 p-3 text-sm text-sky-800">
            Read-only view. Submitting payments, requesting loans, and editing on
            this member's behalf are disabled. Use the savings edit / approvals
            queue on the admin dashboard to act.
          </div>
        )}

        {summary.error && (
          <div className="rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-700">
            {summary.error}
          </div>
        )}

        {summary.loading ? (
          <p className="text-center text-gray-400 py-8">Loading dashboard…</p>
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
        <LogTransactionSheet
          open={sheetOpen}
          onClose={() => setSheetOpen(false)}
          memberId={user?.id}
          unpaidFees={unpaidFees}
          payableInstallments={payableInstallments}
          onSubmitted={handleSubmitted}
        />
      )}
    </div>
  )
}
