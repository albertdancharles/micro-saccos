// MemberGrid renders the same rows twice — as cards for mobile and as a table
// for desktop — so these guard the thing that split makes easy to get wrong:
// the two presentations drifting apart, or an action wiring up to the wrong row.
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { LanguageProvider } from '../../hooks/useLanguage'
import MemberGrid from './MemberGrid'

const rows = [
  {
    id: 'a1',
    name: 'Neema Mwakalinga',
    role: 'admin',
    overall: 'paid',
    fee: { computed_status: 'paid', penalty_due: 0 },
    installment: null,
  },
  {
    id: 'm1',
    name: 'Juma Kileo',
    role: 'member',
    overall: 'overdue',
    fee: { computed_status: 'overdue', penalty_due: 2500 },
    installment: { computed_status: 'overdue', total_with_penalty: 18000 },
  },
]

function renderGrid(props = {}) {
  return render(
    <MemoryRouter>
      <LanguageProvider>
        <MemberGrid rows={rows} currentAdminId="a1" {...props} />
      </LanguageProvider>
    </MemoryRouter>,
  )
}

// localStorage carries the language between tests; pin English so assertions
// read against the source strings rather than the Swahili translations.
beforeEach(() => localStorage.setItem('lang', 'en'))

describe('MemberGrid', () => {
  it('renders every member in both the card list and the table', () => {
    renderGrid()
    // One instance per presentation.
    expect(screen.getAllByText('Juma Kileo')).toHaveLength(2)
    expect(screen.getAllByText('Neema Mwakalinga')).toHaveLength(2)
  })

  it('offers the full action set for another member', () => {
    renderGrid()
    for (const label of ['View', 'Edit savings', 'Make admin', 'Delete']) {
      expect(screen.getAllByText(label).length).toBeGreaterThan(0)
    }
  })

  it('does not offer to delete or demote the signed-in admin', () => {
    // Only Juma is actionable that way, so exactly one pair (card + table).
    renderGrid()
    expect(screen.getAllByText('Delete')).toHaveLength(2)
    expect(screen.getAllByText('Make admin')).toHaveLength(2)
  })

  it('passes the right row to an action handler', async () => {
    const onRequestDelete = vi.fn()
    renderGrid({ onRequestDelete })
    await userEvent.click(screen.getAllByText('Delete')[0])
    expect(onRequestDelete).toHaveBeenCalledWith(expect.objectContaining({ id: 'm1' }))
  })

  it('surfaces an overdue fee penalty', () => {
    renderGrid()
    expect(screen.getAllByText(/2,500/).length).toBeGreaterThan(0)
  })

  it('shows an empty state rather than a bare heading', () => {
    render(
      <MemoryRouter>
        <LanguageProvider>
          <MemberGrid rows={[]} currentAdminId="a1" />
        </LanguageProvider>
      </MemoryRouter>,
    )
    expect(screen.getByText('No members yet.')).toBeInTheDocument()
  })

  it('gives every action a touch-sized hit area', () => {
    renderGrid()
    // .tap-action is what pads these to 44px; without it they were ~16px tall.
    const remove = screen.getAllByText('Delete')[0]
    expect(remove).toHaveClass('tap-action')
  })

  it('keeps the mobile cards free of a horizontally scrolling table', () => {
    const { container } = renderGrid()
    const cardList = container.querySelector('ul.md\\:hidden')
    expect(cardList).not.toBeNull()
    expect(within(cardList).queryByRole('table')).toBeNull()
  })
})
