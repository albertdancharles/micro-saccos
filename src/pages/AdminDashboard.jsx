// Admin dashboard (build plan §9, item 31). Calls ensure_current_fees() on mount
// (same safety net as the member dashboard) then renders the summary, member grid,
// and approvals queue. Approving/rejecting refreshes the data.
import { useEffect, useState } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useAdminData } from '../hooks/useAdminData'
import { signOut } from '../lib/auth'
import { supabase } from '../supabaseClient'
import AdminSummaryCards from '../components/admin/AdminSummaryCards'
import MemberGrid from '../components/admin/MemberGrid'
import ApprovalsQueue from '../components/admin/ApprovalsQueue'
import AddMemberModal from '../components/admin/AddMemberModal'
import PoolChart from '../components/admin/PoolChart'
import NotificationsBell from '../components/ui/NotificationsBell'
import DeletionRequestsQueue from '../components/admin/DeletionRequestsQueue'
import RequestDeletionModal from '../components/admin/RequestDeletionModal'
import SavingsEditQueue from '../components/admin/SavingsEditQueue'
import RequestSavingsEditModal from '../components/admin/RequestSavingsEditModal'
import RoleChangeQueue from '../components/admin/RoleChangeQueue'
import RequestRoleChangeModal from '../components/admin/RequestRoleChangeModal'
import PoolEditQueue from '../components/admin/PoolEditQueue'
import RequestPoolEditModal from '../components/admin/RequestPoolEditModal'

export default function AdminDashboard() {
  const { profile, user } = useAuth()
  const navigate = useNavigate()
  const admin = useAdminData()
  const { refresh } = admin
  const [addOpen, setAddOpen] = useState(false)
  const [deleteTarget, setDeleteTarget] = useState(null)
  const [editSavingsTarget, setEditSavingsTarget] = useState(null)
  const [roleChangeTarget, setRoleChangeTarget] = useState(null)
  const [poolEditOpen, setPoolEditOpen] = useState(false)

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
    <div className="min-h-screen bg-[var(--color-app-bg)]">
      <header className="bg-white/85 backdrop-blur-md border-b border-slate-200/70 sticky top-0 z-10">
        <div className="max-w-4xl mx-auto px-6 py-4 flex items-center justify-between gap-3">
          <div className="min-w-0">
            <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-emerald-600">
              Micro-SACCOS · Admin
            </p>
            <h1 className="text-base font-semibold tracking-tight text-slate-900 truncate">
              {profile?.full_name || user?.email}
            </h1>
          </div>
          <div className="flex items-center gap-4 shrink-0">
            <NotificationsBell />
            <Link
              to="/dashboard"
              className="text-sm font-medium text-slate-500 hover:text-slate-800"
            >
              My view
            </Link>
            <Link
              to="/admin/audit"
              className="text-sm font-medium text-slate-500 hover:text-slate-800"
            >
              Audit
            </Link>
            <Link
              to="/profile"
              className="text-sm font-medium text-slate-500 hover:text-slate-800"
            >
              Profile
            </Link>
            <button
              onClick={handleSignOut}
              className="text-sm font-medium text-slate-500 hover:text-slate-800"
            >
              Sign out
            </button>
          </div>
        </div>
      </header>

      <main className="max-w-4xl mx-auto px-6 py-6 space-y-4">
        {admin.error && (
          <div className="rounded-xl border border-red-200/70 bg-red-50 p-3 text-sm text-red-700">
            {admin.error}
          </div>
        )}

        {admin.loading ? (
          <p className="text-center text-slate-400 py-8">Loading…</p>
        ) : (
          <>
            <AdminSummaryCards
              stats={admin.stats}
              onEditTotalAssets={() => setPoolEditOpen(true)}
            />
            <PoolChart />
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
            <div className="flex justify-end">
              <button
                onClick={() => setAddOpen(true)}
                className="inline-flex items-center justify-center min-h-11 rounded-xl bg-white text-emerald-700 text-sm font-medium px-4 ring-1 ring-inset ring-emerald-200 hover:bg-emerald-50 hover:ring-emerald-300 active:scale-[0.99] transition-all duration-150"
              >
                + Add member
              </button>
            </div>
            <MemberGrid
              rows={admin.gridRows}
              currentAdminId={user?.id}
              onRequestDelete={setDeleteTarget}
              onRequestEditSavings={setEditSavingsTarget}
              onRequestRoleChange={setRoleChangeTarget}
            />
          </>
        )}
      </main>

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
      <RequestRoleChangeModal
        open={!!roleChangeTarget}
        target={roleChangeTarget}
        onClose={() => setRoleChangeTarget(null)}
        onSubmitted={refresh}
      />
    </div>
  )
}
