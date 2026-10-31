// A monthly settlement that needs a second admin arrives as many pending rows. These
// guard the point of folding them: one signature for the batch, and the rows still
// reachable for anyone who wants to look at (or reject) a single one.
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { LanguageProvider } from '../../hooks/useLanguage'
import ApprovalsQueue from './ApprovalsQueue'

const rpc = vi.fn()
vi.mock('../../supabaseClient', () => ({
  supabase: { rpc: (...args) => rpc(...args) },
}))

const auth = { user: { id: 'me' }, isOverseer: false }
vi.mock('../../hooks/useAuth', () => ({ useAuth: () => auth }))

const pending = (id, extra = {}) => ({
  id,
  member_id: `member-${id}`,
  memberName: `Member ${id}`,
  submission_type: 'loan_installment',
  amount_claimed: 5000,
  suggested: 5000,
  penalty: 0,
  installmentNumber: 1,
  dueDate: '2026-10-31',
  obligation: null,
  outstanding: 0,
  proof_url: null,
  recordedByName: 'Kelvin Sinde',
  approvalsCount: 1,
  requiredApprovals: 2,
  approverNames: ['Kelvin Sinde'],
  iApproved: false,
  isSelf: false,
  canApprove: true,
  firstAmount: 5000,
  settlement_batch_id: 'batch-1',
  ...extra,
})

function renderQueue(pendingPayments, props = {}) {
  return render(
    <LanguageProvider>
      <ApprovalsQueue pendingLoans={[]} pendingPayments={pendingPayments} {...props} />
    </LanguageProvider>,
  )
}

const signAll = () => screen.getByRole('button', { name: /^Sign all/ })

beforeEach(() => {
  localStorage.setItem('lang', 'en')
  rpc.mockReset()
  auth.isOverseer = false
})

describe('ApprovalsQueue — a monthly settlement', () => {
  it('folds a batch into one card with one signature', () => {
    renderQueue([pending('1'), pending('2'), pending('3')])
    expect(screen.getAllByRole('button', { name: /^Sign all/ })).toHaveLength(1)
    expect(signAll()).toHaveTextContent('15,000')
  })

  it('fences the recorder\'s name off from the page translator', () => {
    renderQueue([pending('1')])
    const names = screen.getAllByText('Kelvin Sinde')
    expect(names[0]).toHaveAttribute('translate', 'no')
  })

  it('signs the whole batch with one press', async () => {
    rpc.mockResolvedValue({
      data: { signed_count: 2, signed_total: 10000, left_count: 0 },
      error: null,
    })
    const onActioned = vi.fn()
    renderQueue([pending('1'), pending('2')], { onActioned })

    await userEvent.click(signAll())

    expect(rpc).toHaveBeenCalledTimes(1)
    expect(rpc).toHaveBeenCalledWith('approve_monthly_settlement', { p_batch_id: 'batch-1' })
    await waitFor(() => expect(onActioned).toHaveBeenCalled())
  })

  it('keeps each row reachable behind the card', () => {
    renderQueue([pending('1'), pending('2')])
    expect(screen.getByText('See each payment')).toBeInTheDocument()
    expect(screen.getByText('Member 1')).toBeInTheDocument()
    expect(screen.getByText('Member 2')).toBeInTheDocument()
  })

  it('offers only Reject on a row inside a batch, because signing is the card\'s job', () => {
    renderQueue([pending('1'), pending('2')])
    expect(screen.queryByRole('button', { name: /approv/i, hidden: true })).toBeNull()
    expect(screen.getAllByRole('button', { name: 'Reject', hidden: true })).toHaveLength(2)
  })

  it('tells the admin who recorded it that someone else has to sign', () => {
    renderQueue([pending('1', { iApproved: true, canApprove: false })])
    expect(signAll()).toBeDisabled()
    expect(screen.getByText(/Another admin has to finish them/)).toBeInTheDocument()
  })

  it('leaves a signer\'s own money out of what they sign, and says so', () => {
    renderQueue([pending('1'), pending('2', { isSelf: true, canApprove: false })])
    expect(signAll()).toHaveTextContent('5,000')
    expect(screen.getByText(/Your own payment here needs another admin/)).toBeInTheDocument()
  })

  it('lets the overseer sign their own money too', () => {
    auth.isOverseer = true
    renderQueue([pending('1'), pending('2', { isSelf: true })])
    expect(signAll()).toHaveTextContent('10,000')
    expect(screen.queryByText(/Your own payment here/)).toBeNull()
  })

  it('needs a reason to reject the batch', async () => {
    rpc.mockResolvedValue({ data: 2, error: null })
    const onActioned = vi.fn()
    renderQueue([pending('1'), pending('2')], { onActioned })

    await userEvent.click(screen.getByRole('button', { name: 'Reject all' }))
    await userEvent.click(screen.getByRole('button', { name: 'Confirm reject' }))
    expect(rpc).not.toHaveBeenCalled()
    expect(screen.getByText('Add a short reason for the rejection.')).toBeInTheDocument()

    await userEvent.type(screen.getByPlaceholderText('Reason for rejection'), 'Too early')
    await userEvent.click(screen.getByRole('button', { name: 'Confirm reject' }))
    expect(rpc).toHaveBeenCalledWith('reject_monthly_settlement', {
      p_batch_id: 'batch-1',
      p_reason: 'Too early',
    })
    await waitFor(() => expect(onActioned).toHaveBeenCalled())
  })

  it('shows the server\'s refusal on the card', async () => {
    rpc.mockResolvedValue({ data: null, error: new Error('Member 1’s figure has changed') })
    renderQueue([pending('1')])
    await userEvent.click(signAll())
    expect(await screen.findByText(/figure has changed/)).toBeInTheDocument()
  })

  it('leaves payments keyed on their own exactly as they were', () => {
    renderQueue([pending('1', { settlement_batch_id: null })])
    expect(screen.queryByRole('button', { name: /^Sign all/ })).toBeNull()
    expect(screen.getByText('Member 1')).toBeInTheDocument()
  })
})
