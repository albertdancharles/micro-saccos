// App routing (build plan §3). Public auth routes + a protected tree; RoleHome at
// "/" sends admins to /admin and members to /dashboard.
//
// Pages are code-split via React.lazy so a member never downloads admin code (and
// vice-versa) and the heavy recharts chart bundle stays off the first paint. Login
// is kept eager — it's the entry point for unauthenticated users, so lazying it would
// just add a round-trip before first paint.
import { lazy, Suspense } from 'react'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { AuthProvider } from './hooks/useAuth'
import { LanguageProvider } from './hooks/useLanguage'
import ErrorBoundary from './components/ErrorBoundary'
import ProtectedRoute from './routes/ProtectedRoute'
import RoleHome from './routes/RoleHome'
import Login from './pages/Login'

const UpdatePassword = lazy(() => import('./pages/UpdatePassword'))
const MemberDashboard = lazy(() => import('./pages/MemberDashboard'))
const AdminDashboard = lazy(() => import('./pages/AdminDashboard'))
const Profile = lazy(() => import('./pages/Profile'))
const AuditLog = lazy(() => import('./pages/AuditLog'))
const ViewMember = lazy(() => import('./pages/ViewMember'))

// Shown briefly while a route's chunk loads. Dependency-free so it stays in the
// entry chunk and paints instantly.
function RouteFallback() {
  return (
    <div className="min-h-screen flex items-center justify-center">
      <div className="skeleton h-24 w-full max-w-md mx-4" />
    </div>
  )
}

export default function App() {
  return (
    <ErrorBoundary>
    <LanguageProvider>
    <AuthProvider>
      <BrowserRouter>
        <Suspense fallback={<RouteFallback />}>
        <Routes>
          <Route path="/login" element={<Login />} />
          <Route path="/update-password" element={<UpdatePassword />} />

          <Route element={<ProtectedRoute />}>
            <Route path="/" element={<RoleHome />} />
            <Route path="/dashboard" element={<MemberDashboard />} />
            <Route path="/profile" element={<Profile />} />
          </Route>

          <Route element={<ProtectedRoute requireAdmin />}>
            <Route path="/admin" element={<AdminDashboard />} />
            <Route path="/admin/audit" element={<AuditLog />} />
            <Route path="/admin/member/:memberId" element={<ViewMember />} />
          </Route>

          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
        </Suspense>
      </BrowserRouter>
    </AuthProvider>
    </LanguageProvider>
    </ErrorBoundary>
  )
}
