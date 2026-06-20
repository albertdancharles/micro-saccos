// Catches render-time crashes anywhere in the routed tree so a single bad
// component shows a recoverable fallback instead of a blank white screen.
// Must be a class component — React only supports error boundaries this way.
// The fallback is intentionally bilingual and dependency-free: if something is
// broken enough to land here, we don't want to rely on app context to render.
import { Component } from 'react'

export default class ErrorBoundary extends Component {
  state = { hasError: false }

  static getDerivedStateFromError() {
    return { hasError: true }
  }

  componentDidCatch(error, info) {
    console.error('Unhandled UI error', error, info)
  }

  render() {
    if (!this.state.hasError) return this.props.children
    return (
      <div className="min-h-screen flex items-center justify-center p-6 bg-app-bg">
        <div className="max-w-sm w-full rounded-2xl border border-slate-200/70 bg-white p-6 text-center shadow-card">
          <h1 className="text-base font-semibold text-slate-900">Something went wrong</h1>
          <p className="mt-1 text-sm text-slate-500">Kuna hitilafu. Tafadhali jaribu tena.</p>
          <button onClick={() => window.location.reload()} className="btn-primary w-full mt-4">
            Reload · Pakia upya
          </button>
        </div>
      </div>
    )
  }
}
