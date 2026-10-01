// The member dashboard has two headers — the member's own, and the one an admin
// sees while inspecting that member — and both put a person's name on screen.
// Only the first was fenced from machine translation, so Eva appeared to an admin
// as "Eve" (Chrome's page translator rewrites every text node it can reach; see
// src/components/ui/Name.jsx). These guard both.
//
// The summary hook is mocked as still loading, which is what keeps this cheap:
// the body renders as a skeleton and the header — the thing under test — is all
// that is left.
import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { LanguageProvider } from '../hooks/useLanguage'

vi.mock('../hooks/useAuth', () => ({
  useAuth: () => ({
    profile: { id: 'm1', full_name: 'Amani Ngoko' },
    user: { id: 'm1', email: 'amani@example.test' },
  }),
}))

vi.mock('../hooks/useMemberSummary', () => ({
  useMemberSummary: () => ({ loading: true, error: '' }),
}))

vi.mock('../lib/auth', () => ({ signOut: vi.fn() }))

const { default: MemberDashboard } = await import('./MemberDashboard')

function renderDashboard(props = {}) {
  return render(
    <MemoryRouter>
      <LanguageProvider>
        <MemberDashboard {...props} />
      </LanguageProvider>
    </MemoryRouter>,
  )
}

describe('MemberDashboard header', () => {
  it('fences the member’s own name from the page translator', () => {
    const { container } = renderDashboard()

    const name = screen.getByText('Amani Ngoko')
    expect(name.closest('[translate="no"]')).not.toBeNull()
    expect(container.querySelector('[translate="no"]')).not.toBeNull()
  })

  // The regression: an admin opening a member's page saw the name translated.
  it('fences the viewed member’s name when an admin is looking', () => {
    renderDashboard({ viewAs: 'm2', viewedName: 'Eva' })

    const name = screen.getByText('Eva')
    expect(name.closest('[translate="no"]')).not.toBeNull()
  })

  // The eyebrow and the rest of the page are exactly what a reader asked to have
  // translated, so fencing must not spread beyond the name itself.
  it('leaves the label around the name translatable', () => {
    renderDashboard({ viewAs: 'm2', viewedName: 'Eva' })

    const eyebrow = screen.getByText('Inaangalia kama msimamizi')
    expect(eyebrow.closest('[translate="no"]')).toBeNull()
  })

  it('falls back to a translated label when the name is not known yet', () => {
    renderDashboard({ viewAs: 'm2', viewedName: null })

    expect(screen.getByText('Mwanachama')).toBeInTheDocument()
  })
})
