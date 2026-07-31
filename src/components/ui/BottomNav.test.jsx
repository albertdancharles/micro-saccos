// BottomNav replaced the header text links that used to be the only way around
// the app on a phone, so these cover the parts that would strand a user: the
// wrong tab set for a role, or no indication of where they currently are.
import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { LanguageProvider } from '../../hooks/useLanguage'
import BottomNav from './BottomNav'

function renderNav({ isAdmin = false, at = '/dashboard' } = {}) {
  localStorage.setItem('lang', 'en')
  return render(
    <MemoryRouter initialEntries={[at]}>
      <LanguageProvider>
        <BottomNav isAdmin={isAdmin} />
      </LanguageProvider>
    </MemoryRouter>,
  )
}

describe('BottomNav', () => {
  it('gives members the three destinations they can reach', () => {
    renderNav()
    expect(screen.getByRole('link', { name: /Home/ })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: /Members/ })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: /Profile/ })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: /Admin/ })).not.toBeInTheDocument()
  })

  it('adds the admin destination for admins', () => {
    renderNav({ isAdmin: true, at: '/admin' })
    expect(screen.getAllByRole('link')).toHaveLength(4)
    expect(screen.getByRole('link', { name: /Admin/ })).toBeInTheDocument()
  })

  it('marks the current route with aria-current, which also drives its styling', () => {
    renderNav({ at: '/members' })
    expect(screen.getByRole('link', { name: /Members/ })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('link', { name: /Home/ })).not.toHaveAttribute('aria-current')
  })

  it('does not mark the admin tab active while on a nested admin page', () => {
    // `end` on that tab keeps /admin/audit from lighting up the Admin tab as if
    // it were the dashboard itself.
    renderNav({ isAdmin: true, at: '/admin/audit' })
    expect(screen.getByRole('link', { name: /Admin/ })).not.toHaveAttribute('aria-current')
  })

  it('labels itself for screen readers', () => {
    renderNav()
    expect(screen.getByRole('navigation', { name: 'Main navigation' })).toBeInTheDocument()
  })
})
