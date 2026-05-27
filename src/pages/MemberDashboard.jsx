// Member dashboard (build plan §9, item 23). Calls ensure_current_fees() on mount
// (self-healing fee generation, §8c-bis) then loads the summary and renders the
// member flows. A "Log transaction" sheet feeds new proofs into the approvals queue.
import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
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

export default function MemberDashboard() {
  const { profile, user } = useAuth()
  const navigate = useNavigate()
  const summary = useMemberSummary()
  const { refresh } = summary
  const [sheetOpen, setSheetOpen] = useState(false)
  const [version, setVersion] = useState(0) // bumps to refetch history after a submit

  // Self-healing fee generation, then refresh so the current fee shows immediately.
  useEffect(() => {
    if (!supabase) return
    supabase.rpc('ensure_current_fees').then(({ error }) => {
      if (error) console.error('ensure_current_fees failed', error)
      refresh()
    })
  }, [refresh])

  function handleSubmitted() {
    refresh()
    setVersion((v) => v + 1)
  }

  async function handleSignOut() {
    await signOut()
    navigate('/login', { replace: true })
  }

  const unpaidFees = summary.fees.filter((f) => f.computed_status !== 'paid')
  const payableInstallments = summary.installments.filter((i) => i.computed_status !== 'paid')

  return (
    <div className="min-h-screen bg-gray-50">
      <header className="bg-white border-b border-gray-100 sticky top-0 z-10">
        <div className="max-w-md mx-auto px-6 py-4 flex items-center justify-between">
          <div className="min-w-0">
            <p className="text-xs text-gray-400">Micro-SACCOS</p>
            <h1 className="text-lg font-semibold text-gray-900 truncate">
              {profile?.full_name || user?.email}
            </h1>
          </div>
          <button onClick={handleSignOut} className="text-sm text-gray-500 hover:text-gray-700 shrink-0">
            Sign out
          </button>
        </div>
      </header>

      <main className="max-w-md mx-auto px-6 py-6 space-y-4">
        <button
          onClick={() => setSheetOpen(true)}
          className="w-full rounded-xl bg-emerald-600 text-white font-medium py-3 hover:bg-emerald-700 transition-colors"
        >
          + Log a transaction
        </button>

        {summary.error && (
          <div className="rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-700">
            {summary.error}
          </div>
        )}

        {summary.loading ? (
          <p className="text-center text-gray-400 py-8">Loading your dashboard…</p>
        ) : (
          <>
            <SummaryCards
              pool={summary.pool}
              savings={summary.savings}
              loan={summary.loan}
              amountDue={summary.amountDue}
              penaltyDue={summary.penaltyDue}
            />
            <ObligationsCard
              fees={summary.fees}
              installments={summary.installments}
              currentMonthKey={summary.currentMonthKey}
            />
            <RepaymentSchedule
              installments={summary.installments}
              currentMonthKey={summary.currentMonthKey}
            />
            <LoanRequestForm
              memberId={user?.id}
              savings={summary.savings}
              loan={summary.loan}
              onSubmitted={handleSubmitted}
            />
            <History refreshKey={version} />
          </>
        )}
      </main>

      <LogTransactionSheet
        open={sheetOpen}
        onClose={() => setSheetOpen(false)}
        memberId={user?.id}
        unpaidFees={unpaidFees}
        payableInstallments={payableInstallments}
        onSubmitted={handleSubmitted}
      />
    </div>
  )
}
