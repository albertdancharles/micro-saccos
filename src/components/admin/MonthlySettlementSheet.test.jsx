// One press settles the whole group, so what is worth pinning is what stands between
// that press and everyone's account: nothing posts without a confirmation, unticked
// members are really left out, and the figure confirmed is the figure sent.
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { LanguageProvider } from '../../hooks/useLanguage'
import MonthlySettlementSheet from './MonthlySettlementSheet'

const rpc = vi.fn()
vi.mock('../../supabaseClient', () => ({
  supabase: { rpc: (...args) => rpc(...args) },
}))

const auth = { user: { id: 'me' }, isOverseer: true }
vi.mock('../../hooks/useAuth', () => ({ useAuth: () => auth }))

const row = (kind, member, name, amount, extra = {}) => ({
  kind,
  related_id: `${kind}-${member}`,
  member_id: member,
  full_name: name,
  due_date: '2026-10-31',
  period: kind === 'fee' ? '2026-10-01' : null,
  installment_number: kind === 'fee' ? null : 1,
  base: amount,
  penalty: 0,
  amount,
  needs_second_signature: false,
  ...extra,
})

const SHEET = [
  row('fee', 'a', 'Amani Juma', 10000),
  row('interest', 'a', 'Amani Juma', 26635),
  row('fee', 'b', 'Neema Paulo', 10000),
]

// Answers the two RPCs the sheet makes; `settle` is what the write resolves to.
function serve(
  sheet = SHEET,
  settle = {
    data: { settled_count: 3, settled_total: 46635, awaiting_count: 0, awaiting_total: 0 },
    error: null,
  },
) {
  rpc.mockImplementation(async (name) => {
    if (name === 'monthly_settlement_sheet') return { data: sheet, error: null }
    if (name === 'record_monthly_settlement') return settle
    throw new Error(`unexpected rpc ${name}`)
  })
}

const settleCalls = () => rpc.mock.calls.filter(([name]) => name === 'record_monthly_settlement')

function renderSheet(props = {}) {
  return render(
    <LanguageProvider>
      <MonthlySettlementSheet {...props} />
    </LanguageProvider>,
  )
}

async function renderOpen(props = {}) {
  renderSheet(props)
  await userEvent.click(await screen.findByRole('button', { name: 'Review and settle everyone' }))
}

const settleButton = () => screen.getByRole('button', { name: /^Settle / })

beforeEach(() => {
  localStorage.setItem('lang', 'en')
  rpc.mockReset()
  auth.isOverseer = true
})

describe('MonthlySettlementSheet', () => {
  it('shows what is due before anything is opened', async () => {
    serve()
    renderSheet()
    expect(await screen.findByText(/46,635/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Review and settle everyone' })).toBeInTheDocument()
  })

  it('starts with everybody ticked', async () => {
    serve()
    await renderOpen()
    for (const box of screen.getAllByRole('checkbox')) expect(box).toBeChecked()
    expect(settleButton()).toHaveTextContent('46,635')
  })

  it('fences every name off from the page translator', async () => {
    serve()
    await renderOpen()
    expect(screen.getByText('Amani Juma')).toHaveAttribute('translate', 'no')
  })

  it('never posts on the first press', async () => {
    serve()
    await renderOpen()
    await userEvent.click(settleButton())
    expect(settleCalls()).toHaveLength(0)
    expect(screen.getByRole('button', { name: 'Yes, settle' })).toBeInTheDocument()
  })

  it('sends everybody, and the total it showed, once confirmed', async () => {
    serve()
    const onActioned = vi.fn()
    await renderOpen({ onActioned })
    await userEvent.click(settleButton())
    await userEvent.click(screen.getByRole('button', { name: 'Yes, settle' }))

    await waitFor(() => expect(settleCalls()).toHaveLength(1))
    expect(settleCalls()[0][1]).toEqual({
      p_entries: [
        { kind: 'fee', id: 'fee-a' },
        { kind: 'interest', id: 'interest-a' },
        { kind: 'fee', id: 'fee-b' },
      ],
      p_expected_total: 46635,
    })
    await waitFor(() => expect(onActioned).toHaveBeenCalled())
  })

  it('leaves out a member who is unticked, whole', async () => {
    serve()
    await renderOpen()
    await userEvent.click(screen.getByRole('checkbox', { name: 'Amani Juma' }))
    expect(settleButton()).toHaveTextContent('10,000')

    await userEvent.click(settleButton())
    await userEvent.click(screen.getByRole('button', { name: 'Yes, settle' }))

    await waitFor(() => expect(settleCalls()).toHaveLength(1))
    expect(settleCalls()[0][1]).toEqual({
      p_entries: [{ kind: 'fee', id: 'fee-b' }],
      p_expected_total: 10000,
    })
  })

  it('can leave out one line of a member who paid only part', async () => {
    serve()
    await renderOpen()
    await userEvent.click(screen.getByRole('checkbox', { name: /Interest/ }))

    const member = screen.getByRole('checkbox', { name: 'Amani Juma' })
    expect(member).not.toBeChecked()
    expect(member.indeterminate).toBe(true)
    expect(settleButton()).toHaveTextContent('20,000')
  })

  it('backs out of the confirmation when the selection changes under it', async () => {
    serve()
    await renderOpen()
    await userEvent.click(settleButton())
    await userEvent.click(screen.getByRole('checkbox', { name: 'Neema Paulo' }))
    expect(screen.queryByRole('button', { name: 'Yes, settle' })).toBeNull()
    expect(settleButton()).toHaveTextContent('36,635')
  })

  it('has nothing to press when everyone is unticked', async () => {
    serve()
    await renderOpen()
    await userEvent.click(screen.getByRole('button', { name: 'Untick everyone' }))
    expect(settleButton()).toBeDisabled()
    await userEvent.click(screen.getByRole('button', { name: 'Tick everyone' }))
    expect(settleButton()).toBeEnabled()
  })

  it('says what will wait for a second admin, before the press', async () => {
    auth.isOverseer = false
    serve([
      row('fee', 'b', 'Neema Paulo', 10000),
      row('interest', 'b', 'Neema Paulo', 5000, { needs_second_signature: true }),
    ])
    await renderOpen()
    expect(screen.getByText(/needs a second admin/)).toHaveTextContent('5,000')
  })

  it('says it all posts now when nothing has to wait', async () => {
    serve()
    await renderOpen()
    expect(screen.getByText(/posts immediately on your signature/)).toBeInTheDocument()
  })

  it('reports what posted and what is waiting, then closes', async () => {
    serve(SHEET, {
      data: { settled_count: 1, settled_total: 10000, awaiting_count: 2, awaiting_total: 36635 },
      error: null,
    })
    await renderOpen()
    await userEvent.click(settleButton())
    await userEvent.click(screen.getByRole('button', { name: 'Yes, settle' }))

    const status = await screen.findByRole('status')
    expect(within(status).getByText(/is recorded/)).toHaveTextContent('10,000')
    expect(within(status).getByText(/waiting for a second admin/)).toHaveTextContent('36,635')
    expect(screen.queryByRole('button', { name: 'Yes, settle' })).toBeNull()
  })

  it('shows the server\'s refusal and stays open, with nothing lost', async () => {
    serve(SHEET, {
      data: null,
      error: new Error('The total is now TSh 1 but this sheet showed TSh 2.'),
    })
    await renderOpen()
    await userEvent.click(screen.getByRole('checkbox', { name: 'Neema Paulo' }))
    await userEvent.click(settleButton())
    await userEvent.click(screen.getByRole('button', { name: 'Yes, settle' }))

    expect(await screen.findByText(/The total is now/)).toBeInTheDocument()
    expect(screen.getByRole('checkbox', { name: 'Neema Paulo' })).not.toBeChecked()
    expect(settleButton()).toBeEnabled()
  })

  it('says so plainly when nothing is due, and offers nothing to press', async () => {
    serve([])
    renderSheet()
    expect(await screen.findByText(/Nothing is due right now/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Review and settle everyone' })).toBeNull()
  })

  it('does not take the dashboard down if the sheet cannot load', async () => {
    rpc.mockResolvedValue({ data: null, error: new Error('function does not exist') })
    const quiet = vi.spyOn(console, 'error').mockImplementation(() => {})
    renderSheet()
    expect(await screen.findByText('Could not load the month’s settlement.')).toBeInTheDocument()
    quiet.mockRestore()
  })

  it('reloads when the dashboard\'s data changes', async () => {
    serve()
    const ui = (signal) => (
      <LanguageProvider>
        <MonthlySettlementSheet refreshSignal={signal} />
      </LanguageProvider>
    )
    const { rerender } = render(ui('one'))
    await screen.findByText(/46,635/)
    const loads = () =>
      rpc.mock.calls.filter(([name]) => name === 'monthly_settlement_sheet').length
    expect(loads()).toBe(1)
    rerender(ui('two'))
    await waitFor(() => expect(loads()).toBe(2))
  })
})
