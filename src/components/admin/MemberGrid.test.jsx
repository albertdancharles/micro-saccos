// MemberGrid renders the same rows twice — as cards for mobile and as a table
// for desktop — so these guard the thing that split makes easy to get wrong:
// the two presentations drifting apart, or an action wiring up to the wrong row.
// Actions now live behind a per-row overflow menu, so most of these open one
// first; that trigger is the only route to them, which makes it worth asserting.
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

// Both presentations render at once in jsdom (the breakpoint is CSS-only), so
// index 0 is the card list's menu and index 1 the table's.
async function openMenu(name, presentation = 0) {
  const triggers = screen.getAllByRole('button', { name: `Actions for ${name}` })
  expect(triggers).toHaveLength(2)
  await userEvent.click(triggers[presentation])
  return screen.getByRole('menu', { name: `Actions for ${name}` })
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

  it('offers the full action set for another member', async () => {
    renderGrid()
    const menu = await openMenu('Juma Kileo')
    for (const label of ['View', 'Edit savings', 'Make admin', 'Delete']) {
      expect(within(menu).getByRole('menuitem', { name: label })).toBeInTheDocument()
    }
  })

  it('does not offer to delete or demote the signed-in admin', async () => {
    renderGrid()
    const menu = await openMenu('Neema Mwakalinga')
    expect(within(menu).queryByRole('menuitem', { name: 'Delete' })).toBeNull()
    expect(within(menu).queryByRole('menuitem', { name: 'Revoke admin' })).toBeNull()
    expect(within(menu).getByRole('menuitem', { name: 'View' })).toBeInTheDocument()
  })

  it('passes the right row to an action handler', async () => {
    const onRequestDelete = vi.fn()
    renderGrid({ onRequestDelete })
    const menu = await openMenu('Juma Kileo')
    await userEvent.click(within(menu).getByRole('menuitem', { name: 'Delete' }))
    expect(onRequestDelete).toHaveBeenCalledWith(expect.objectContaining({ id: 'm1' }))
  })

  it('closes the menu on Escape', async () => {
    renderGrid()
    await openMenu('Juma Kileo')
    await userEvent.keyboard('{Escape}')
    expect(screen.queryByRole('menu')).toBeNull()
  })

  it('links a member name straight to their detail view', () => {
    renderGrid()
    const [link] = screen.getAllByRole('link', { name: 'Juma Kileo' })
    expect(link).toHaveAttribute('href', '/admin/member/m1')
  })

  it('surfaces an overdue fee penalty', () => {
    renderGrid()
    expect(screen.getAllByText(/2,500/).length).toBeGreaterThan(0)
  })

  it('counts overdue members in the header', () => {
    renderGrid()
    expect(screen.getByText('1 overdue')).toBeInTheDocument()
  })

  it('shows a dash, not a status pill, where a member has no loan', () => {
    renderGrid()
    // Neema has no installment, in both presentations.
    expect(screen.getAllByText('—')).toHaveLength(2)
    expect(screen.queryByText('N/A')).toBeNull()
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

  it('gives every action a touch-sized hit area', async () => {
    renderGrid()
    const menu = await openMenu('Juma Kileo')
    // min-h-11 is 44px — Apple's HIG minimum, and the app-wide floor.
    for (const item of within(menu).getAllByRole('menuitem')) {
      expect(item).toHaveClass('min-h-11')
    }
    expect(screen.getAllByRole('button', { name: 'Actions for Juma Kileo' })[0]).toHaveClass('size-11')
  })

  it('keeps the mobile cards free of a horizontally scrolling table', () => {
    const { container } = renderGrid()
    const cardList = container.querySelector('ul.md\\:hidden')
    expect(cardList).not.toBeNull()
    expect(within(cardList).queryByRole('table')).toBeNull()
  })
})
