// Shared app header.
//
// Previously every page inlined its own header with up to five text links in a
// `shrink-0` row. Inside a max-w-md container that left the member's own name
// ~100px before truncating, and each link was a ~16px-tall tap target.
//
// Now the header carries identity plus the two always-available controls
// (language, notifications), and navigation moves to BottomNav on mobile. The
// inline links come back at >=640px, where there's room for them.
import { Link } from 'react-router-dom'
import { useLanguage } from '../../hooks/useLanguage'
import LangToggle from './LangToggle'
import NotificationsBell from './NotificationsBell'

export default function AppHeader({
  eyebrow,
  title,
  // Sub-pages pass a back target. On mobile it renders as an icon button on the
  // left — the platform-conventional position — so no flow is a dead end even
  // when that destination has no tab of its own.
  back = null,
  // Desktop-only inline nav. Mobile reaches these through the tab bar.
  links = [],
  onSignOut = null,
  showControls = true,
  // Member views are max-w-md; the admin dashboard is wider. The header's inner
  // container matches its page so the two stay optically aligned.
  width = 'max-w-md',
}) {
  const { t } = useLanguage()

  return (
    <header className="sticky top-0 z-30 border-b border-slate-200/70 bg-white/85 backdrop-blur-md pt-safe">
      <div
        className={`${width} mx-auto flex items-center justify-between gap-3 px-4 py-3 sm:px-6 sm:py-4`}
      >
        <div className="flex min-w-0 items-center gap-1">
          {back && (
            <Link
              to={back.to}
              aria-label={back.label}
              className="-ml-2 inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-full text-slate-500 transition-colors hover:bg-slate-100 hover:text-slate-800 active:bg-slate-200/70 sm:hidden"
            >
              <svg
                viewBox="0 0 24 24"
                width="20"
                height="20"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                aria-hidden
              >
                <path d="M15 5l-7 7 7 7" />
              </svg>
            </Link>
          )}
          <div className="min-w-0">
            {eyebrow && (
              <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-emerald-600">
                {eyebrow}
              </p>
            )}
            <h1 className="truncate text-base font-semibold tracking-tight text-slate-900">
              {title}
            </h1>
          </div>
        </div>

        <div className="flex shrink-0 items-center gap-1 sm:gap-3">
          {showControls && (
            <>
              <LangToggle />
              <NotificationsBell />
            </>
          )}

          {/* Desktop-only nav. Hidden on mobile, where BottomNav owns these. */}
          {links.length > 0 && (
            <nav className="hidden items-center gap-4 sm:flex" aria-label={t('Main navigation')}>
              {links.map((l) => (
                <Link
                  key={l.to}
                  to={l.to}
                  className="text-sm font-medium text-slate-500 transition-colors hover:text-slate-800"
                >
                  {l.label}
                </Link>
              ))}
            </nav>
          )}

          {/* Sign out stays in the desktop header; on mobile it lives on the
              Profile screen, where account actions are conventionally found. */}
          {onSignOut && (
            <button
              onClick={onSignOut}
              className="hidden text-sm font-medium text-slate-500 transition-colors hover:text-slate-800 sm:block"
            >
              {t('Sign out')}
            </button>
          )}

          {/* Back link as text on desktop, where the icon button is hidden. */}
          {back && (
            <Link
              to={back.to}
              className="hidden text-sm font-medium text-slate-500 transition-colors hover:text-slate-800 sm:block"
            >
              {back.label}
            </Link>
          )}
        </div>
      </div>
    </header>
  )
}
