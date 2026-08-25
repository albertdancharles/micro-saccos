// App routing (build plan §3). Public auth routes + a protected tree; RoleHome at
// "/" sends admins to /admin and members to /dashboard.
//
// Pages are code-split via React.lazy so a member never downloads admin code (and
// vice-versa) and each route stays off the first paint. Login is kept eager — it's the
// entry point for unauthenticated users, so lazying it would just add a round-trip
// before first paint.
import { lazy, Suspense } from 'react'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { AuthProvider } from './hooks/useAuth'
import { LanguageProvider } from './hooks/useLanguage'
import { GroupSettingsProvider } from './hooks/useGroupSettings'
import ErrorBoundary from './components/ErrorBoundary'
import ProtectedRoute from './routes/ProtectedRoute'
import RoleHome from './routes/RoleHome'
import Login from './pages/Login'

const UpdatePassword = lazy(() => import('./pages/UpdatePassword'))
const MemberDashboard = lazy(() => import('./pages/MemberDashboard'))
const AdminDashboard = lazy(() => import('./pages/AdminDashboard'))
const Profile = lazy(() => import('./pages/Profile'))
const GroupMembers = lazy(() => import('./pages/GroupMembers'))
const AuditLog = lazy(() => import('./pages/AuditLog'))
const ViewMember = lazy(() => import('./pages/ViewMember'))
const Cycles = lazy(() => import('./pages/Cycles'))
const Reports = lazy(() => import('./pages/Reports'))
const Meetings = lazy(() => import('./pages/Meetings'))

// Shown briefly while a route's chunk loads. Dependency-free so it stays in the
// entry chunk and paints instantly.
function RouteFallback() {
  return (
    <div className="min-h-dvh flex items-center justify-center">
      <div className="skeleton h-24 w-full max-w-md mx-4" />
    </div>
  )
}

export default function App() {
  return (
    <ErrorBoundary>
    <LanguageProvider>
    <GroupSettingsProvider>
    <AuthProvider>
      <BrowserRouter>
        <Suspense fallback={<RouteFallback />}>
        <Routes>
          <Route path="/login" element={<Login />} />
          <Route path="/update-password" element={<UpdatePassword />} />

          {/* No /signup, /complete-profile or /pending. Membership is not something
              you apply for any more: an admin creates the account (and the KYC with
              it) through the admin-create-member Edge Function and hands over a
              temporary password. Removing the pages is only half of it — email
              signups must also be turned off in the Supabase Auth dashboard, or the
              endpoint is still open even with no UI pointing at it. */}

          <Route element={<ProtectedRoute />}>
            <Route path="/" element={<RoleHome />} />
            <Route path="/dashboard" element={<MemberDashboard />} />
            <Route path="/members" element={<GroupMembers />} />
            <Route path="/profile" element={<Profile />} />
          </Route>

          <Route element={<ProtectedRoute requireAdmin />}>
            <Route path="/admin" element={<AdminDashboard />} />
            <Route path="/admin/audit" element={<AuditLog />} />
            <Route path="/admin/cycles" element={<Cycles />} />
            <Route path="/admin/reports" element={<Reports />} />
            <Route path="/admin/meetings" element={<Meetings />} />
            <Route path="/admin/member/:memberId" element={<ViewMember />} />
          </Route>

          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
        </Suspense>
      </BrowserRouter>
    </AuthProvider>
    </GroupSettingsProvider>
    </LanguageProvider>
    </ErrorBoundary>
  )
}
