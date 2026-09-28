// This panel exists because exited members used to be rendered as job applicants,
// behind an "Approve member" button and a "Reject" that deletes the account and
// cascades away the history exit deliberately keeps. Its inertness is the fix, so
// it is the thing worth asserting.
import { beforeEach, describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { LanguageProvider } from '../../hooks/useLanguage'
import FormerMembersPanel from './FormerMembersPanel'

const wrap = (ui) => render(<LanguageProvider>{ui}</LanguageProvider>)
beforeEach(() => localStorage.setItem('lang', 'en'))

describe('FormerMembersPanel', () => {
  it('lists who has left', () => {
    wrap(
      <FormerMembersPanel
        formerMembers={[
          { id: 'a', full_name: 'Departed Member', role: 'member' },
          { id: 'b', full_name: 'Another Leaver', role: 'member' },
        ]}
      />,
    )
    expect(screen.getByText('Departed Member')).toBeInTheDocument()
    expect(screen.getByText('Another Leaver')).toBeInTheDocument()
  })

  it('offers no action on a former member', () => {
    wrap(<FormerMembersPanel formerMembers={[{ id: 'a', full_name: 'Departed Member' }]} />)
    expect(screen.queryByRole('button')).toBeNull()
    expect(screen.queryByRole('link')).toBeNull()
  })

  it('renders nothing when nobody has left', () => {
    const { container } = wrap(<FormerMembersPanel formerMembers={[]} />)
    expect(container).toBeEmptyDOMElement()
  })
})
