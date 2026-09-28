// The overseer row (041). protect_overseer() refuses to demote, deactivate or
// delete the overseer in SQL, so the grid must not offer those three actions —
// an action that can only ever return an error is worse than no action. The
// badge is the other half: an admin looking at the roster should be able to see
// who signs alone, because that is not visible anywhere else.
//
// Kept in its own file so it does not collide with MemberGrid.test.jsx.
import { beforeEach, describe, expect, it } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { LanguageProvider } from '../../hooks/useLanguage'
import MemberGrid from './MemberGrid'

const OVERSEER = {
  id: 'o1',
  name: 'Albert Charles',
  role: 'admin',
  isOverseer: true,
  overall: 'paid',
  fee: { computed_status: 'paid', penalty_due: 0 },
  installment: null,
}

const PLAIN_ADMIN = {
  id: 'a2',
  name: 'Neema Mwakalinga',
  role: 'admin',
  overall: 'paid',
  fee: { computed_status: 'paid', penalty_due: 0 },
  installment: null,
}

// currentAdminId is a third party: the overseer's own row would be suppressed by
// the existing isSelf rules, which would hide what these tests are checking.
function renderGrid(rows) {
  return render(
    <MemoryRouter>
      <LanguageProvider>
        <MemberGrid rows={rows} currentAdminId="someone-else" />
      </LanguageProvider>
    </MemoryRouter>,
  )
}

async function openMenu(name) {
  const triggers = screen.getAllByRole('button', { name: `Actions for ${name}` })
  await userEvent.click(triggers[0])
  return screen.getByRole('menu', { name: `Actions for ${name}` })
}

beforeEach(() => localStorage.setItem('lang', 'en'))

describe('MemberGrid — the overseer', () => {
  it('captions the overseer as Overseer rather than Admin', () => {
    renderGrid([OVERSEER])
    // One caption per presentation, card and table.
    expect(screen.getAllByText('Overseer')).toHaveLength(2)
    expect(screen.queryByText('Admin')).toBeNull()
  })

  it('still captions an ordinary admin as Admin', () => {
    renderGrid([PLAIN_ADMIN])
    expect(screen.getAllByText('Admin')).toHaveLength(2)
    expect(screen.queryByText('Overseer')).toBeNull()
  })

  // View and Edit savings are already withheld on any other admin's row, so
  // withholding the remaining three leaves the overseer row with no actions at
  // all — and the grid then renders no menu trigger for it whatsoever.
  it('renders no action menu at all on the overseer row', () => {
    renderGrid([OVERSEER])
    expect(screen.queryAllByRole('button', { name: `Actions for ${OVERSEER.name}` })).toHaveLength(0)
  })

  it('still offers all three against an ordinary admin', async () => {
    renderGrid([PLAIN_ADMIN])
    const menu = await openMenu(PLAIN_ADMIN.name)
    expect(within(menu).getByText('Revoke admin')).toBeTruthy()
    expect(within(menu).getByText('Settle & exit')).toBeTruthy()
    expect(within(menu).getByText('Delete')).toBeTruthy()
  })
})
