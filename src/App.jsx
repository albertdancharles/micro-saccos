// App routing (build plan §3). Public auth routes + a protected tree; RoleHome at
// "/" sends admins to /admin and members to /dashboard.
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { AuthProvider } from './hooks/useAuth'
import ProtectedRoute from './routes/ProtectedRoute'
import RoleHome from './routes/RoleHome'
import Login from './pages/Login'
import UpdatePassword from './pages/UpdatePassword'
import MemberDashboard from './pages/MemberDashboard'
import AdminDashboard from './pages/AdminDashboard'
import Profile from './pages/Profile'

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
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
          </Route>

          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  )
}
