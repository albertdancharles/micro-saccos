// The two figures are one number seen twice: total assets is the pool plus what is out on
// loans, and only the pool can be edited. So what is worth pinning is that typing in either
// box sends the same delta, and that a figure the pool cannot reach never leaves the form.
// That the delta really applies on one signature is 14_overseer.test.sql's job.
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { LanguageProvider } from '../../hooks/useLanguage'
import RequestPoolEditModal from './RequestPoolEditModal'

const rpc = vi.fn()
vi.mock('../../supabaseClient', () => ({
  supabase: { rpc: (...args) => rpc(...args) },
}))

const STATS = { pool: 1000000, outstandingLoans: 3000000, totalAssets: 4000000 }

const poolBox = () => screen.getByLabelText('Group pool')
const totalBox = () => screen.getByLabelText('Total group assets')
const reasonBox = () => screen.getByLabelText('Reason')
const applyButton = () => screen.getByRole('button', { name: 'Apply adjustment' })

function renderForm(props = {}) {
  return render(
    <LanguageProvider>
      <RequestPoolEditModal open onClose={() => {}} stats={STATS} {...props} />
    </LanguageProvider>,
  )
}

async function setFigure(box, value) {
  await userEvent.clear(box)
  await userEvent.type(box, value)
}

beforeEach(() => {
  localStorage.setItem('lang', 'en')
  rpc.mockReset()
  rpc.mockResolvedValue({ data: 'new-id', error: null })
})

describe('adjusting the pool and total assets', () => {
  it('opens on the figures as they stand today', () => {
    renderForm()
    expect(poolBox()).toHaveValue(1000000)
    expect(totalBox()).toHaveValue(4000000)
  })

  it('moves total assets with the pool, and sends the difference', async () => {
    const onSubmitted = vi.fn()
    const onClose = vi.fn()
    renderForm({ onSubmitted, onClose })

    await setFigure(poolBox(), '1500000')
    expect(totalBox()).toHaveValue(4500000)

    await userEvent.type(reasonBox(), 'Interest from the bank')
    await userEvent.click(applyButton())

    await waitFor(() =>
      expect(rpc).toHaveBeenCalledWith('request_pool_edit', {
        p_delta: 500000,
        p_reason: 'Interest from the bank',
      }),
    )
    await waitFor(() => expect(onSubmitted).toHaveBeenCalledTimes(1))
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('moves the pool with total assets, and can bring both down', async () => {
    renderForm()

    await setFigure(totalBox(), '3750000')
    expect(poolBox()).toHaveValue(750000)

    await userEvent.type(reasonBox(), 'Correcting a mis-entry')
    await userEvent.click(applyButton())

    await waitFor(() =>
      expect(rpc).toHaveBeenCalledWith('request_pool_edit', {
        p_delta: -250000,
        p_reason: 'Correcting a mis-entry',
      }),
    )
  })

  it('accepts a pool of exactly zero', async () => {
    renderForm()

    await setFigure(poolBox(), '0')
    await userEvent.type(reasonBox(), 'Handed to the treasurer')
    await userEvent.click(applyButton())

    await waitFor(() =>
      expect(rpc).toHaveBeenCalledWith('request_pool_edit', {
        p_delta: -1000000,
        p_reason: 'Handed to the treasurer',
      }),
    )
  })

  // The attribute, because jsdom does not enforce step. Without it a real browser refuses
  // to submit a figure with cents, on a box the overseer may never have touched.
  it('lets the browser accept figures with cents', () => {
    renderForm({ stats: { pool: 1000.1, outstandingLoans: 2000.2, totalAssets: 3000.3 } })
    expect(poolBox()).toHaveAttribute('step', 'any')
    expect(totalBox()).toHaveAttribute('step', 'any')
    expect(totalBox()).toHaveValue(3000.3)
  })

  it('sends a clean delta when the books hold cents', async () => {
    renderForm({ stats: { pool: 1000.1, outstandingLoans: 2000.2, totalAssets: 3000.3 } })

    await setFigure(totalBox(), '3000.6')
    await userEvent.type(reasonBox(), 'Cents')
    await userEvent.click(applyButton())

    await waitFor(() =>
      expect(rpc).toHaveBeenCalledWith('request_pool_edit', { p_delta: 0.3, p_reason: 'Cents' }),
    )
  })

  it('refuses total assets below what is out on loans', async () => {
    renderForm()

    await setFigure(totalBox(), '2000000')
    await userEvent.type(reasonBox(), 'Too far')
    await userEvent.click(applyButton())

    expect(await screen.findByText(/would leave the pool negative/)).toBeInTheDocument()
    expect(rpc).not.toHaveBeenCalled()
  })

  it.each([
    ['an unchanged figure', null],
    ['an emptied box', ''],
  ])('refuses %s', async (_label, value) => {
    renderForm()

    if (value !== null) await userEvent.clear(poolBox())
    await userEvent.type(reasonBox(), 'No change')
    await userEvent.click(applyButton())

    expect(await screen.findByText('Enter a figure different from today’s.')).toBeInTheDocument()
    expect(rpc).not.toHaveBeenCalled()
  })

  it('refuses an adjustment with no reason', async () => {
    renderForm()

    await setFigure(poolBox(), '1500000')
    await userEvent.click(applyButton())

    expect(await screen.findByText('A reason is required for every pool edit.')).toBeInTheDocument()
    expect(rpc).not.toHaveBeenCalled()
  })

  it('says it applies at once, not that other admins must approve', () => {
    renderForm()
    expect(screen.getByText(/on your signature alone/)).toBeInTheDocument()
    expect(screen.queryByText(/Two other admins/)).not.toBeInTheDocument()
  })

  it('stays open and shows the error when the database refuses', async () => {
    const onClose = vi.fn()
    rpc.mockResolvedValue({
      data: null,
      error: new Error('A pending pool edit already exists; cancel or approve it first'),
    })
    renderForm({ onClose })

    await setFigure(poolBox(), '1500000')
    await userEvent.type(reasonBox(), 'Interest')
    await userEvent.click(applyButton())

    expect(await screen.findByText(/A pending pool edit already exists/)).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
  })
})
