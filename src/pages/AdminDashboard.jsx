// Admin dashboard (build plan §9, item 31). Calls ensure_current_fees() on mount
// (same safety net as the member dashboard) then renders the summary, member grid,
// and approvals queue. Approving/rejecting refreshes the data.
import { useEffect, useState } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'

import { useLanguage } from '../hooks/useLanguage'
import { useAdminData } from '../hooks/useAdminData'
import { signOut } from '../lib/auth'
import { supabase } from '../supabaseClient'
import AdminSummaryCards from '../components/admin/AdminSummaryCards'
import MemberGrid from '../components/admin/MemberGrid'
import ApprovalsQueue from '../components/admin/ApprovalsQueue'
import AddMemberModal from '../components/admin/AddMemberModal'
import AppHeader from '../components/ui/AppHeader'
import BottomNav from '../components/ui/BottomNav'
import PendingMembersQueue from '../components/admin/PendingMembersQueue'
import DeletionRequestsQueue from '../components/admin/DeletionRequestsQueue'
import RequestDeletionModal from '../components/admin/RequestDeletionModal'
import SavingsEditQueue from '../components/admin/SavingsEditQueue'
import RequestSavingsEditModal from '../components/admin/RequestSavingsEditModal'
import RoleChangeQueue from '../components/admin/RoleChangeQueue'
import RequestRoleChangeModal from '../components/admin/RequestRoleChangeModal'
import PoolEditQueue from '../components/admin/PoolEditQueue'
import RequestPoolEditModal from '../components/admin/RequestPoolEditModal'
import SettingChangeQueue from '../components/admin/SettingChangeQueue'
import SettingsPanel from '../components/admin/SettingsPanel'
import LoanActionQueue from '../components/admin/LoanActionQueue'
import ActiveLoansPanel from '../components/admin/ActiveLoansPanel'
import WithdrawalQueue from '../components/admin/WithdrawalQueue'
import RequestMemberExitModal from '../components/admin/RequestMemberExitModal'
import ReconciliationBanner from '../components/admin/ReconciliationBanner'
import MessagingBanner from '../components/admin/MessagingBanner'
import PoolChart from '../components/admin/PoolChart'
import RecordFeeSheet from '../components/admin/RecordFeeSheet'
import RecordPaymentModal from '../components/admin/RecordPaymentModal'
import FileLoanModal from '../components/admin/FileLoanModal'
import AdminWithdrawalModal from '../components/admin/AdminWithdrawalModal'
import CorrectionsPanel from '../components/admin/CorrectionsPanel'

export default function AdminDashboard() {
  const { profile, user } = useAuth()
  const { t } = useLanguage()
  const navigate = useNavigate()
  const admin = useAdminData()
  const { refresh } = admin
  const [addOpen, setAddOpen] = useState(false)
  const [deleteTarget, setDeleteTarget] = useState(null)
  const [editSavingsTarget, setEditSavingsTarget] = useState(null)
  const [roleChangeTarget, setRoleChangeTarget] = useState(null)
  const [exitTarget, setExitTarget] = useState(null)
  const [poolEditOpen, setPoolEditOpen] = useState(false)
  const [recordOpen, setRecordOpen] = useState(false)
  const [fileLoanOpen, setFileLoanOpen] = useState(false)
  const [withdrawalOpen, setWithdrawalOpen] = useState(false)

  // The modals want { id, full_name }; the grid speaks { id, name }.
  const members = admin.gridRows.map((r) => ({ id: r.id, full_name: r.name }))

  useEffect(() => {
    if (!supabase) return
    supabase.rpc('ensure_current_fees').then(({ error }) => {
      if (error) console.error('ensure_current_fees failed', error)
      refresh()
    })
  }, [refresh])

  async function handleSignOut() {
    await signOut()
    navigate('/login', { replace: true })
  }

  return (
    <div className="min-h-dvh bg-[var(--color-app-bg)]">
      <AppHeader
        eyebrow={t('Micro-SACCOS · Admin')}
        title={profile?.full_name || user?.email}
        width="max-w-4xl"
        links={[
          { to: '/dashboard', label: t('My view') },
          { to: '/admin/audit', label: t('Audit') },
          { to: '/profile', label: t('Profile') },
        ]}
        onSignOut={handleSignOut}
      />

      <main className="max-w-4xl mx-auto px-4 sm:px-6 py-5 sm:py-6 space-y-4 pb-nav">
        {admin.error && (
          <div className="rounded-xl border border-red-200/70 bg-red-50 p-3 text-sm text-red-700">
            {admin.error}
          </div>
        )}

        {admin.loading ? (
          <p className="text-center text-slate-400 py-8">{t('Loading…')}</p>
        ) : (
          <>
            {/* Above everything: if the books don't balance, nothing else on this
                page can be trusted. Renders nothing when they do. */}
            <ReconciliationBanner reconciliation={admin.reconciliation} />
            {/* Also silent unless something is wrong: reminders piling up unsent. */}
            <MessagingBanner messaging={admin.messaging} />
            <AdminSummaryCards
              stats={admin.stats}
              onEditTotalAssets={() => setPoolEditOpen(true)}
            />
            <PoolChart />

            {/* The intake. Members file nothing now (migration 034), so every
                shilling that enters the system starts on one of these three
                controls. They sit above the approval queues because recording is
                the daily work; approving is what happens to what was recorded. */}
            <RecordFeeSheet onActioned={refresh} />
            <div className="grid grid-cols-2 gap-3">
              <button
                onClick={() => setRecordOpen(true)}
                className="inline-flex items-center justify-center min-h-11 rounded-xl bg-white text-emerald-700 text-sm font-medium px-4 ring-1 ring-inset ring-emerald-200 hover:bg-emerald-50 hover:ring-emerald-300 active:scale-[0.99] transition-all duration-150"
              >
                {t('Record a payment')}
              </button>
              <button
                onClick={() => setFileLoanOpen(true)}
                className="inline-flex items-center justify-center min-h-11 rounded-xl bg-white text-emerald-700 text-sm font-medium px-4 ring-1 ring-inset ring-emerald-200 hover:bg-emerald-50 hover:ring-emerald-300 active:scale-[0.99] transition-all duration-150"
              >
                {t('File a loan')}
              </button>
              <button
                onClick={() => setWithdrawalOpen(true)}
                className="col-span-2 inline-flex items-center justify-center min-h-11 rounded-xl bg-white text-slate-600 text-sm font-medium px-4 ring-1 ring-inset ring-slate-200 hover:bg-slate-50 hover:ring-slate-300 active:scale-[0.99] transition-all duration-150"
              >
                {t('Open a withdrawal')}
              </button>
            </div>
            <CorrectionsPanel onActioned={refresh} />

            <PendingMembersQueue pendingMembers={admin.pendingMembers} onActioned={refresh} />
            <ApprovalsQueue
              pendingLoans={admin.pendingLoans}
              pendingPayments={admin.pendingPayments}
              onActioned={refresh}
            />
            <DeletionRequestsQueue
              pendingDeletions={admin.pendingDeletions}
              onActioned={refresh}
            />
            <SavingsEditQueue
              pendingSavingsEdits={admin.pendingSavingsEdits}
              onActioned={refresh}
            />
            <RoleChangeQueue
              pendingRoleChanges={admin.pendingRoleChanges}
              onActioned={refresh}
            />
            <PoolEditQueue
              pendingPoolEdits={admin.pendingPoolEdits}
              stats={admin.stats}
              onActioned={refresh}
            />
            <SettingChangeQueue
              pendingSettingChanges={admin.pendingSettingChanges}
              onActioned={refresh}
            />
            <WithdrawalQueue
              pendingWithdrawals={admin.pendingWithdrawals}
              onActioned={refresh}
            />
            <LoanActionQueue
              pendingLoanActions={admin.pendingLoanActions}
              onActioned={refresh}
            />
            <ActiveLoansPanel activeLoans={admin.activeLoans} onActioned={refresh} />
            {/* Audit log has no tab of its own, and the header link that used to
                reach it is desktop-only — so it gets a first-class entry point
                here, where mobile admins can actually find it. */}
            <div className="grid grid-cols-2 gap-3">
              <button
                onClick={() => setAddOpen(true)}
                className="inline-flex items-center justify-center min-h-11 rounded-xl bg-white text-emerald-700 text-sm font-medium px-4 ring-1 ring-inset ring-emerald-200 hover:bg-emerald-50 hover:ring-emerald-300 active:scale-[0.99] transition-all duration-150"
              >
                {t('+ Add member')}
              </button>
              <Link
                to="/admin/audit"
                className="inline-flex items-center justify-center min-h-11 rounded-xl bg-white text-slate-600 text-sm font-medium px-4 ring-1 ring-inset ring-slate-200 hover:bg-slate-50 hover:ring-slate-300 active:scale-[0.99] transition-all duration-150"
              >
                {t('Audit log')}
              </Link>
              <Link
                to="/admin/cycles"
                className="inline-flex items-center justify-center min-h-11 rounded-xl bg-white text-sky-700 text-sm font-medium px-4 ring-1 ring-inset ring-sky-200 hover:bg-sky-50 hover:ring-sky-300 active:scale-[0.99] transition-all duration-150"
              >
                {t('Cycles & share-out')}
              </Link>
              <Link
                to="/admin/reports"
                className="inline-flex items-center justify-center min-h-11 rounded-xl bg-white text-sky-700 text-sm font-medium px-4 ring-1 ring-inset ring-sky-200 hover:bg-sky-50 hover:ring-sky-300 active:scale-[0.99] transition-all duration-150"
              >
                {t('Group report')}
              </Link>
              <Link
                to="/admin/meetings"
                className="col-span-2 inline-flex items-center justify-center min-h-11 rounded-xl bg-white text-sky-700 text-sm font-medium px-4 ring-1 ring-inset ring-sky-200 hover:bg-sky-50 hover:ring-sky-300 active:scale-[0.99] transition-all duration-150"
              >
                {t('Meetings & social fund')}
              </Link>
            </div>
            <MemberGrid
              rows={admin.gridRows}
              currentAdminId={user?.id}
              onRequestDelete={setDeleteTarget}
              onRequestEditSavings={setEditSavingsTarget}
              onRequestRoleChange={setRoleChangeTarget}
              onRequestExit={setExitTarget}
            />
            <SettingsPanel rows={admin.settingRows} onChanged={refresh} />
          </>
        )}
      </main>

      <RecordPaymentModal
        open={recordOpen}
        onClose={() => setRecordOpen(false)}
        members={members}
        onSubmitted={refresh}
      />
      <FileLoanModal
        open={fileLoanOpen}
        onClose={() => setFileLoanOpen(false)}
        members={members}
        onSubmitted={refresh}
      />
      <AdminWithdrawalModal
        open={withdrawalOpen}
        onClose={() => setWithdrawalOpen(false)}
        members={members}
        onSubmitted={refresh}
      />
      <AddMemberModal open={addOpen} onClose={() => setAddOpen(false)} onCreated={refresh} />
      <RequestDeletionModal
        open={!!deleteTarget}
        target={deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onSubmitted={refresh}
      />
      <RequestSavingsEditModal
        open={!!editSavingsTarget}
        target={editSavingsTarget}
        onClose={() => setEditSavingsTarget(null)}
        onSubmitted={refresh}
      />
      <RequestPoolEditModal
        open={poolEditOpen}
        stats={admin.stats}
        onClose={() => setPoolEditOpen(false)}
        onSubmitted={refresh}
      />
      <RequestMemberExitModal
        open={!!exitTarget}
        target={exitTarget}
        onClose={() => setExitTarget(null)}
        onSubmitted={refresh}
      />
      <RequestRoleChangeModal
        open={!!roleChangeTarget}
        target={roleChangeTarget}
        adminCount={admin.stats.adminCount}
        onClose={() => setRoleChangeTarget(null)}
        onSubmitted={refresh}
      />

      <BottomNav isAdmin />
    </div>
  )
}
