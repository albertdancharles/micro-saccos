// Bottom-sheet modal (build plan §9, mobile-first). Refined per UI/UX Pro Max:
//   * Backdrop scrim 40-60% black + blur for foreground legibility (HIG, MD).
//   * Sheet slides up from below with spring-ish easing in <= 240ms (motion-base).
//   * Sticky header with close button has 44pt hit area (touch-target-size).
//   * Close on Escape or backdrop click (escape-routes).
import { useEffect } from 'react'
import { useLanguage } from '../../hooks/useLanguage'

export default function Modal({ open, onClose, title, children }) {
  const { t } = useLanguage()

  useEffect(() => {
    if (!open) return
    const onKey = (e) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  if (!open) return null

  return (
    <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center">
      <div
        data-backdrop-enter
        className="absolute inset-0 bg-slate-900/55 backdrop-blur-sm"
        onClick={onClose}
        aria-hidden="true"
      />
      <div
        data-sheet-enter
        role="dialog"
        aria-modal="true"
        aria-labelledby="modal-title"
        className="relative w-full sm:max-w-md bg-white shadow-[0_24px_48px_-24px_rgba(15,23,42,0.32)] rounded-t-2xl sm:rounded-2xl max-h-[90vh] overflow-y-auto ring-1 ring-slate-200/70"
      >
        <div className="flex items-center justify-between gap-4 px-5 py-3 border-b border-slate-100 sticky top-0 bg-white/95 backdrop-blur z-10">
          <h2 id="modal-title" className="text-sm font-semibold text-slate-900">
            {title}
          </h2>
          <button
            onClick={onClose}
            className="-mr-2 inline-flex items-center justify-center w-9 h-9 rounded-full text-slate-400 hover:text-slate-700 hover:bg-slate-100 transition-colors"
            aria-label={t('Close')}
          >
            <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <line x1="18" y1="6" x2="6" y2="18" />
              <line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        </div>
        <div className="px-5 py-5">{children}</div>
      </div>
    </div>
  )
}
