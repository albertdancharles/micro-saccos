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

export default function AdminDashboard() {
  const { profile, user } = useAuth()
  const navigate = useNavigate()
  const admin = useAdminData()
  const { refresh } = admin
  const [addOpen, setAddOpen] = useState(false)
  const [deleteTarget, setDeleteTarget] = useState(null)
  const [editSavingsTarget, setEditSavingsTarget] = useState(null)

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
    <div className="min-h-screen bg-gray-50">
      <header className="bg-white border-b border-gray-100 sticky top-0 z-10">
        <div className="max-w-4xl mx-auto px-6 py-4 flex items-center justify-between">
          <div className="min-w-0">
            <p className="text-xs text-gray-400">Micro-SACCOS · Admin</p>
            <h1 className="text-lg font-semibold text-gray-900 truncate">
              {profile?.full_name || user?.email}
            </h1>
          </div>
          <div className="flex items-center gap-4 shrink-0">
            <NotificationsBell />
            {/* Admin is also a contributing member (Decision #1). */}
            <Link to="/dashboard" className="text-sm text-gray-500 hover:text-gray-700">
              My member view
            </Link>
            <Link to="/admin/audit" className="text-sm text-gray-500 hover:text-gray-700">
              Audit log
            </Link>
            <Link to="/profile" className="text-sm text-gray-500 hover:text-gray-700">
              Profile
            </Link>
            <button onClick={handleSignOut} className="text-sm text-gray-500 hover:text-gray-700">
              Sign out
            </button>
          </div>
        </div>
      </header>

      <main className="max-w-4xl mx-auto px-6 py-6 space-y-4">
        {admin.error && (
          <div className="rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-700">
            {admin.error}
          </div>
        )}

        {admin.loading ? (
          <p className="text-center text-gray-400 py-8">Loading…</p>
        ) : (
          <>
            <AdminSummaryCards stats={admin.stats} />
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
            <div className="flex justify-end">
              <button
                onClick={() => setAddOpen(true)}
                className="rounded-lg border border-emerald-600 text-emerald-700 text-sm font-medium px-4 py-2 hover:bg-emerald-50"
              >
                + Add member
              </button>
            </div>
            <MemberGrid
              rows={admin.gridRows}
              currentAdminId={user?.id}
              onRequestDelete={setDeleteTarget}
              onRequestEditSavings={setEditSavingsTarget}
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
    </div>
  )
}
