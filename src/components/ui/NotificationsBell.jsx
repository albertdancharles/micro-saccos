// Notifications bell + dropdown. Live-updates via the useNotifications hook;
// click outside or Escape to close. UI/UX Pro Max: 44pt touch target,
// focus-visible ring, soft-shadow popover with backdrop-blur, refined dot tokens.
import { useEffect, useRef, useState } from 'react'
import { useNotifications } from '../../hooks/useNotifications'
import { useLanguage } from '../../hooks/useLanguage'

const KIND_DOT = {
  submission_approved: 'bg-emerald-500',
  loan_active: 'bg-emerald-500',
  loan_closed: 'bg-emerald-500',
  submission_rejected: 'bg-red-500',
  loan_rejected: 'bg-red-500',
  new_submission: 'bg-amber-500',
  new_loan: 'bg-amber-500',
  deletion_requested: 'bg-red-500',
  savings_edit_requested: 'bg-amber-500',
  savings_edited: 'bg-emerald-500',
  pool_edit_requested: 'bg-sky-500',
  role_change_requested: 'bg-amber-500',
  role_changed: 'bg-emerald-500',
}

function relativeTime(iso, t) {
  if (!iso) return ''
  const seconds = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 1000))
  if (seconds < 60) return t('just now')
  if (seconds < 3600) return t('{n}m ago').replace('{n}', Math.floor(seconds / 60))
  if (seconds < 86400) return t('{n}h ago').replace('{n}', Math.floor(seconds / 3600))
  return t('{n}d ago').replace('{n}', Math.floor(seconds / 86400))
}

function BellIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="20"
      height="20"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9" />
      <path d="M10.3 21a1.94 1.94 0 0 0 3.4 0" />
    </svg>
  )
}

export default function NotificationsBell() {
  const { items, unreadCount, markAllRead } = useNotifications()
  const { t } = useLanguage()
  const [open, setOpen] = useState(false)
  const ref = useRef(null)

  useEffect(() => {
    if (!open) return
    function onDown(e) {
      if (ref.current && !ref.current.contains(e.target)) setOpen(false)
    }
    function onKey(e) {
      if (e.key === 'Escape') setOpen(false)
    }
    // touchstart as well as mousedown: on touch devices the emulated mouse event
    // only arrives after the browser rules out a gesture, which reads as lag when
    // you tap away to dismiss.
    window.addEventListener('mousedown', onDown)
    window.addEventListener('touchstart', onDown, { passive: true })
    window.addEventListener('keydown', onKey)
    return () => {
      window.removeEventListener('mousedown', onDown)
      window.removeEventListener('touchstart', onDown)
      window.removeEventListener('keydown', onKey)
    }
  }, [open])

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen((o) => !o)}
        className="relative inline-flex items-center justify-center w-11 h-11 rounded-full text-slate-500 hover:text-slate-800 hover:bg-slate-100/70 active:bg-slate-200/70 transition-colors"
        aria-label={`${t('Notifications')}${unreadCount ? ` (${unreadCount} unread)` : ''}`}
        aria-haspopup="dialog"
        aria-expanded={open}
      >
        <BellIcon />
        {unreadCount > 0 && (
          <span className="absolute top-1.5 right-1.5 inline-flex items-center justify-center min-w-[16px] h-4 px-1 rounded-full bg-red-500 text-white text-[10px] font-semibold leading-none ring-2 ring-white tabular-nums">
            {unreadCount > 9 ? '9+' : unreadCount}
          </span>
        )}
      </button>

      {open && (
        <div
          data-sheet-enter
          role="dialog"
          aria-label={t('Notifications')}
          // 320px would spill off a 320px-wide iPhone SE once the header's own
          // padding is counted, so cap against the viewport. overscroll-contain
          // stops a flick inside the list from scrolling the page behind it.
          className="absolute right-0 mt-2 w-[min(20rem,calc(100vw-2rem))] max-h-[min(24rem,60vh)] overflow-y-auto overscroll-contain rounded-2xl bg-white/95 backdrop-blur shadow-[0_6px_14px_-8px_rgba(15,23,42,0.12),0_12px_32px_-16px_rgba(15,23,42,0.18)] ring-1 ring-slate-200/70 z-30"
        >
          <div className="flex items-center justify-between px-4 py-3 border-b border-slate-100 sticky top-0 bg-white/95 backdrop-blur">
            <p className="text-sm font-semibold tracking-tight text-slate-900">{t('Notifications')}</p>
            {unreadCount > 0 && (
              <button
                onClick={markAllRead}
                className="tap-action text-emerald-700 hover:text-emerald-800"
              >
                {t('Mark all read')}
              </button>
            )}
          </div>
          {items.length === 0 ? (
            <p className="px-4 py-8 text-sm text-slate-400 text-center">
              {t('No notifications yet.')}
            </p>
          ) : (
            <ul className="divide-y divide-slate-100">
              {items.map((n) => (
                <li
                  key={n.id}
                  className={`px-4 py-3 transition-colors ${
                    !n.read_at ? 'bg-emerald-50/40' : 'hover:bg-slate-50/60'
                  }`}
                >
                  <div className="flex items-start gap-2.5">
                    <span
                      className={`mt-1.5 w-2 h-2 rounded-full shrink-0 ${
                        KIND_DOT[n.kind] || 'bg-slate-400'
                      }`}
                    />
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-medium text-slate-900">{n.title}</p>
                      {n.body && <p className="text-xs text-slate-500 mt-0.5">{n.body}</p>}
                      <p className="text-xs text-slate-400 mt-1 tabular-nums">
                        {relativeTime(n.created_at, t)}
                      </p>
                    </div>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  )
}
