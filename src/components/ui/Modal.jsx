// Bottom-sheet modal (build plan §9, mobile-first). Refined per UI/UX Pro Max:
//   * Backdrop scrim 40-60% black + blur for foreground legibility (HIG, MD).
//   * Sheet slides up from below with spring-ish easing in <= 240ms (motion-base).
//   * Sticky header with close button has 44pt hit area (touch-target-size).
//   * Close on Escape or backdrop click (escape-routes).
//
// Mobile specifics handled here:
//   * Body scroll lock — without it the page behind scrolls under the sheet,
//     and on iOS the sheet's own scroll hands off to the page mid-flick.
//   * 100dvh, not 100vh, so the sheet isn't sized against a viewport that
//     includes Safari's collapsible URL bar.
//   * Bottom padding for the home-indicator inset, since index.html opts into
//     viewport-fit=cover and the submit button sits at the sheet's bottom edge.
import { useEffect, useRef } from 'react'
import { useLanguage } from '../../hooks/useLanguage'

// Tab stops inside the sheet. `:not([disabled])` matters — a submit button
// disabled while the form is posting must not become the wrap target, or Tab
// lands on something that cannot be pressed.
const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

export default function Modal({ open, onClose, title, children }) {
  const { t } = useLanguage()
  const panelRef = useRef(null)

  // Escape closes; Tab is kept inside the sheet.
  //
  // Without the trap, tabbing past the last field walked out of the dialog and
  // into the page behind it — which is still fully rendered, and on the admin
  // dashboard is a page of approve and reject buttons. `aria-modal` tells a
  // screen reader the rest of the page is inert; it does not make it so, and a
  // keyboard user could reach and fire a control the sheet was covering.
  useEffect(() => {
    if (!open) return
    const onKey = (e) => {
      if (e.key === 'Escape') return onClose()
      if (e.key !== 'Tab') return

      const focusable = panelRef.current?.querySelectorAll(FOCUSABLE)
      if (!focusable?.length) return
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      const active = document.activeElement

      // Wrap at both ends, and pull focus back in if it has already escaped
      // (the panel itself is focused on open, and is not in this list).
      if (e.shiftKey && (active === first || !panelRef.current.contains(active))) {
        e.preventDefault()
        last.focus()
      } else if (!e.shiftKey && (active === last || !panelRef.current.contains(active))) {
        e.preventDefault()
        first.focus()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  // Lock the page behind the sheet. Compensating for the scrollbar's width keeps
  // desktop layout from shifting sideways as it disappears; on mobile there's no
  // classic scrollbar so the compensation is simply 0.
  useEffect(() => {
    if (!open) return
    const { body } = document
    const prevOverflow = body.style.overflow
    const prevPadding = body.style.paddingRight
    const scrollbar = window.innerWidth - document.documentElement.clientWidth
    body.style.overflow = 'hidden'
    if (scrollbar > 0) body.style.paddingRight = `${scrollbar}px`
    return () => {
      body.style.overflow = prevOverflow
      body.style.paddingRight = prevPadding
    }
  }, [open])

  // Move focus into the sheet so keyboard and screen-reader users land inside it
  // rather than continuing from wherever they were on the page behind — then hand
  // it back to whatever opened the sheet, so closing returns you where you were
  // instead of at the top of the document.
  useEffect(() => {
    if (!open) return
    const opener = document.activeElement
    panelRef.current?.focus()
    return () => {
      if (opener instanceof HTMLElement && document.contains(opener)) opener.focus()
    }
  }, [open])

  if (!open) return null

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center">
      <div
        data-backdrop-enter
        className="absolute inset-0 bg-slate-900/55 backdrop-blur-sm"
        onClick={onClose}
        aria-hidden="true"
      />
      <div
        ref={panelRef}
        tabIndex={-1}
        data-sheet-enter
        role="dialog"
        aria-modal="true"
        aria-labelledby="modal-title"
        className="relative flex max-h-[92dvh] w-full flex-col overflow-hidden rounded-t-2xl bg-white shadow-[0_24px_48px_-24px_rgba(15,23,42,0.32)] ring-1 ring-slate-200/70 outline-none sm:max-h-[85dvh] sm:max-w-md sm:rounded-2xl"
      >
        {/* Grabber. Purely a visual affordance — it signals "this panel came up
            from the bottom and goes back down", which is what people expect to
            see on a sheet. Hidden once the sheet centres itself on desktop. */}
        <div className="flex justify-center pt-2 sm:hidden" aria-hidden="true">
          <span className="h-1 w-9 rounded-full bg-slate-300" />
        </div>

        <div className="flex items-center justify-between gap-4 border-b border-slate-100 bg-white/95 px-5 py-3 backdrop-blur">
          <h2 id="modal-title" className="text-sm font-semibold text-slate-900">
            {title}
          </h2>
          <button
            onClick={onClose}
            className="-mr-2 inline-flex h-11 w-11 items-center justify-center rounded-full text-slate-400 transition-colors hover:bg-slate-100 hover:text-slate-700 active:bg-slate-200/70"
            aria-label={t('Close')}
          >
            <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <line x1="18" y1="6" x2="6" y2="18" />
              <line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        </div>

        {/* The body scrolls, not the whole sheet, so the header stays put without
            needing sticky positioning. overscroll-contain stops a flick that
            reaches the end of this list from scrolling the page behind it. */}
        <div className="flex-1 overflow-y-auto overscroll-contain px-5 py-5 pb-[max(1.25rem,env(safe-area-inset-bottom))]">
          {children}
        </div>
      </div>
    </div>
  )
}
