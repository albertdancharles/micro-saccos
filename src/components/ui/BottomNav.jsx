// Mobile tab bar. Primary destinations live here rather than as text links in
// the header, where on a 360px screen they collided with the member's own name
// and each sat well under the 44px minimum touch target.
//
// Mobile only — hidden at >=640px by the `.bottom-nav` media query, since the
// header nav has room to show the same destinations inline there.
import { NavLink } from 'react-router-dom'
import { useLanguage } from '../../hooks/useLanguage'

function Icon({ children }) {
  return (
    <svg
      viewBox="0 0 24 24"
      width="22"
      height="22"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      {children}
    </svg>
  )
}

// Drawn to read at 22px on a phone — thin, multi-detail glyphs turn to mush at
// this size, so each shape stays chunky and distinct in silhouette.
const ICONS = {
  home: (
    <Icon>
      <path d="M3 10.5 12 4l9 6.5" />
      <path d="M5.5 9.5V19a1 1 0 0 0 1 1h11a1 1 0 0 0 1-1V9.5" />
    </Icon>
  ),
  members: (
    <Icon>
      <circle cx="9" cy="9" r="3.2" />
      <path d="M3.5 19.5a5.8 5.8 0 0 1 11 0" />
      <path d="M16 6.4a3.2 3.2 0 0 1 0 5.2" />
      <path d="M17.5 14.6a5.6 5.6 0 0 1 3 4.9" />
    </Icon>
  ),
  admin: (
    <Icon>
      <rect x="3.5" y="4.5" width="7" height="7" rx="1.4" />
      <rect x="13.5" y="4.5" width="7" height="7" rx="1.4" />
      <rect x="3.5" y="14.5" width="7" height="5" rx="1.4" />
      <rect x="13.5" y="14.5" width="7" height="5" rx="1.4" />
    </Icon>
  ),
  profile: (
    <Icon>
      <circle cx="12" cy="8.5" r="3.6" />
      <path d="M5 20a7 7 0 0 1 14 0" />
    </Icon>
  ),
}

export default function BottomNav({ isAdmin = false }) {
  const { t } = useLanguage()

  // Members see 3 tabs, admins 4. Past four, labels get too cramped to read at
  // 360px — especially in Swahili, which runs longer than the English source.
  const tabs = isAdmin
    ? [
        { to: '/admin', icon: 'admin', label: t('Admin'), end: true },
        { to: '/dashboard', icon: 'home', label: t('My view') },
        { to: '/members', icon: 'members', label: t('Members') },
        { to: '/profile', icon: 'profile', label: t('Profile') },
      ]
    : [
        { to: '/dashboard', icon: 'home', label: t('Home') },
        { to: '/members', icon: 'members', label: t('Members') },
        { to: '/profile', icon: 'profile', label: t('Profile') },
      ]

  return (
    <nav className="bottom-nav" aria-label={t('Main navigation')}>
      {tabs.map((tab) => (
        // NavLink sets aria-current="page" on the active route, which both tells
        // a screen reader where it is and gives our CSS its active-state hook —
        // no separate data attribute needed.
        <NavLink key={tab.to} to={tab.to} end={tab.end} className="bottom-nav-item">
          {ICONS[tab.icon]}
          <span className="bottom-nav-label">{tab.label}</span>
        </NavLink>
      ))}
    </nav>
  )
}
