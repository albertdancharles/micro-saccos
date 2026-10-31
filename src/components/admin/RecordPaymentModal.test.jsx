// Fines (050) share a form with payments that settle a specific fee or installment, so
// what is worth pinning is where they differ: no row to pick, the group's amount filled
// in, one signature for another member, and a plain statement of where the money goes.
// That the money really does stay out of savings is 23_fine_payments.test.sql's job.
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { LanguageProvider } from '../../hooks/useLanguage'
import RecordPaymentModal from './RecordPaymentModal'
import PaymentQueueItem from './PaymentQueueItem'

const rpc = vi.fn()
const from = vi.fn()
vi.mock('../../supabaseClient', () => ({
  supabase: { rpc: (...args) => rpc(...args), from: (...args) => from(...args) },
}))

const auth = { user: { id: 'me' }, isOverseer: false }
vi.mock('../../hooks/useAuth', () => ({ useAuth: () => auth }))

const group = {
  settings: { attendance_fine_late: 2000, attendance_fine_absent: 4000 },
  refresh: vi.fn(),
}
vi.mock('../../hooks/useGroupSettings', () => ({ useGroupSettings: () => group }))

vi.mock('../../hooks/useSignedProof', () => ({
  useSignedProof: () => ({ proofUrl: null, loadingProof: false, viewProof: () => {}, error: '' }),
}))

const MEMBERS = [
  { id: 'me', full_name: 'Asha Mwinyi' },
  { id: 'other', full_name: 'Neema Paulo' },
]

const LENDING_NOTE =
  'This goes into the group’s money for lending. It does not add to the member’s savings.'

function renderForm(props = {}) {
  return render(
    <LanguageProvider>
      <RecordPaymentModal open onClose={() => {}} members={MEMBERS} {...props} />
    </LanguageProvider>,
  )
}

async function choose({ member = 'other', type }) {
  await userEvent.selectOptions(screen.getByLabelText('Member'), member)
  await userEvent.selectOptions(screen.getByLabelText('Paying for'), type)
}

const amountBox = () => screen.getByLabelText('Amount received (TSh)')
const recordButton = () => screen.getByRole('button', { name: 'Record payment' })

beforeEach(() => {
  localStorage.setItem('lang', 'en')
  rpc.mockReset()
  from.mockReset()
  rpc.mockResolvedValue({ data: 'new-id', error: null })
  auth.isOverseer = false
})

describe('recording a fine', () => {
  it('re-reads the group’s amounts when it opens, so a vote is not missed', () => {
    group.refresh.mockClear()
    renderForm()
    expect(group.refresh).toHaveBeenCalledTimes(1)
  })

  it('offers both fines alongside the other payment types', () => {
    renderForm()
    expect(screen.getByRole('option', { name: 'Fine for arriving late' })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Fine for missing a meeting' })).toBeInTheDocument()
  })

  it.each([
    ['fine_late', 2000],
    ['fine_absent', 4000],
  ])('fills in the amount the group set for %s', async (type, amount) => {
    renderForm()
    await choose({ type })
    expect(amountBox()).toHaveValue(amount)
  })

  it('asks for no fee or installment, and looks none up', async () => {
    renderForm()
    await choose({ type: 'fine_late' })
    expect(screen.queryByLabelText('Which fee')).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Which installment')).not.toBeInTheDocument()
    expect(from).not.toHaveBeenCalled()
  })

  it('sends the fine as its own type with no related row', async () => {
    const onSubmitted = vi.fn()
    renderForm({ onSubmitted })
    await choose({ type: 'fine_absent' })
    await userEvent.click(recordButton())

    await waitFor(() => expect(onSubmitted).toHaveBeenCalled())
    expect(rpc).toHaveBeenCalledWith('record_payment', {
      p_member_id: 'other',
      p_type: 'fine_absent',
      p_related_id: null,
      p_amount: 4000,
      p_proof_url: null,
    })
  })

  it('says the money is for lending and not savings, only on a fine', async () => {
    renderForm()
    await choose({ type: 'savings_deposit' })
    expect(screen.queryByText(LENDING_NOTE)).not.toBeInTheDocument()

    await userEvent.selectOptions(screen.getByLabelText('Paying for'), 'fine_late')
    expect(screen.getByText(LENDING_NOTE)).toBeInTheDocument()
  })

  it('accepts part of a fine, because what arrived is what gets recorded', async () => {
    const onSubmitted = vi.fn()
    renderForm({ onSubmitted })
    await choose({ type: 'fine_absent' })
    await userEvent.clear(amountBox())
    await userEvent.type(amountBox(), '1500')
    await userEvent.click(recordButton())

    await waitFor(() => expect(onSubmitted).toHaveBeenCalled())
    expect(rpc.mock.calls[0][1].p_amount).toBe(1500)
  })

  it('stops a figure above the group’s fine before it reaches the server', async () => {
    renderForm()
    await choose({ type: 'fine_late' })
    await userEvent.clear(amountBox())
    await userEvent.type(amountBox(), '20000')
    await userEvent.click(recordButton())

    expect(await screen.findByText(/This fine is TSh 2,000/)).toBeInTheDocument()
    expect(rpc).not.toHaveBeenCalled()
  })

  it('shows the server’s refusal when the group’s amount has changed underneath it', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'This fine is TSh 1,000.' } })
    renderForm()
    await choose({ type: 'fine_late' })
    await userEvent.click(recordButton())

    expect(await screen.findByText('This fine is TSh 1,000.')).toBeInTheDocument()
  })

  it('does not carry a fine’s amount over to a different payment', async () => {
    renderForm()
    await choose({ type: 'fine_absent' })
    expect(amountBox()).toHaveValue(4000)

    await userEvent.selectOptions(screen.getByLabelText('Paying for'), 'savings_deposit')
    expect(amountBox()).toHaveValue(null)
  })

  it('leaves an amount typed for a deposit alone until a fine replaces it', async () => {
    renderForm()
    await choose({ type: 'savings_deposit' })
    await userEvent.type(amountBox(), '75000')
    expect(amountBox()).toHaveValue(75000)

    await userEvent.selectOptions(screen.getByLabelText('Paying for'), 'fine_late')
    expect(amountBox()).toHaveValue(2000)
  })
})

describe('who signs a fine', () => {
  it('posts another member’s fine on one signature', async () => {
    renderForm()
    await choose({ member: 'other', type: 'fine_late' })
    expect(screen.getByText('This posts immediately on your signature.')).toBeInTheDocument()
  })

  it('still sends an admin’s own fine to a second admin', async () => {
    renderForm()
    await choose({ member: 'me', type: 'fine_late' })
    expect(
      screen.getByText(
        'This is your own money, so a second admin must sign it — even for a monthly fee.',
      ),
    ).toBeInTheDocument()
  })

  it('lets the overseer post their own fine alone', async () => {
    auth.isOverseer = true
    renderForm()
    await choose({ member: 'me', type: 'fine_late' })
    expect(screen.getByText('This posts immediately on your signature.')).toBeInTheDocument()
  })
})

describe('a fine waiting for its second signature', () => {
  it('is named in the approvals queue', () => {
    render(
      <LanguageProvider>
        <PaymentQueueItem
          submission={{
            id: 's1',
            submission_type: 'fine_absent',
            memberName: 'Asha Mwinyi',
            amount_claimed: 4000,
            suggested: 4000,
            firstAmount: 4000,
            approvalsCount: 1,
            requiredApprovals: 2,
            approverNames: ['Asha Mwinyi'],
            canApprove: true,
            penalty: 0,
          }}
        />
      </LanguageProvider>,
    )
    expect(screen.getByText('Fine for missing a meeting')).toBeInTheDocument()
  })
})
