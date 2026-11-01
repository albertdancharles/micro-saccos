// The adjust control is the overseer's alone. An ordinary admin's edit would sit waiting
// on two signatures, and the form is worded for one that applies at once.
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { LanguageProvider } from '../../hooks/useLanguage'
import AdminSummaryCards from './AdminSummaryCards'

const auth = { isOverseer: false }
vi.mock('../../hooks/useAuth', () => ({ useAuth: () => auth }))

const STATS = {
  pool: 1000000,
  outstandingLoans: 3000000,
  totalAssets: 4000000,
  feesPaid: 1,
  feesTotal: 2,
  activeLoans: 1,
  pendingReviews: 0,
}

function renderCards(onEditTotalAssets = () => {}) {
  return render(
    <LanguageProvider>
      <AdminSummaryCards stats={STATS} onEditTotalAssets={onEditTotalAssets} />
    </LanguageProvider>,
  )
}

const adjustButton = () => screen.queryByRole('button', { name: 'Adjust pool and total assets' })

beforeEach(() => {
  localStorage.setItem('lang', 'en')
  auth.isOverseer = false
})

describe('the adjust control on the assets card', () => {
  it('is hidden from an ordinary admin', () => {
    renderCards()
    expect(adjustButton()).not.toBeInTheDocument()
  })

  it('opens the form for the overseer', async () => {
    auth.isOverseer = true
    const onEditTotalAssets = vi.fn()
    renderCards(onEditTotalAssets)

    await userEvent.click(adjustButton())

    expect(onEditTotalAssets).toHaveBeenCalledTimes(1)
  })
})
