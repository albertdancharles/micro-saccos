// What a member sees with two loans, or with a pending loan beside an active one. The
// old dashboard picked one loan, so an active loan could vanish behind a newer request
// and the balance and schedule would quietly understate what was owed.
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { LanguageProvider } from '../../hooks/useLanguage'
import SummaryCards from './SummaryCards'
import ObligationsCard from './ObligationsCard'
import RepaymentSchedule from './RepaymentSchedule'

vi.mock('../../hooks/useGroupSettings', () => ({
  useGroupSettings: () => ({
    settings: { contribution_multiplier: 5, pool_loan_fraction: 0.25 },
  }),
}))

const loan = (id, principal, status = 'active', outstanding = principal) => ({
  id,
  principal,
  status,
  outstanding_principal: status === 'active' ? outstanding : 0,
})

const installment = (id, loanId, interest) => ({
  id,
  loan_id: loanId,
  installment_number: 1,
  due_date: '2026-11-28',
  principal_due: 0,
  interest_due: interest,
  total_with_penalty: interest,
  penalty_due: 0,
  computed_status: 'pending',
})

const renderIt = (ui) => render(<LanguageProvider>{ui}</LanguageProvider>)

const cards = (loans) =>
  renderIt(
    <SummaryCards
      pool={500000}
      outstandingLoans={0}
      totalAssets={10000000}
      savings={200000}
      contribution={200000}
      loans={loans}
      amountDue={0}
      penaltyDue={0}
    />,
  )

const text = () => document.body.textContent

beforeEach(() => localStorage.setItem('lang', 'en'))

describe('SummaryCards with several loans', () => {
  it('adds every active loan into the balance', () => {
    cards([loan('a', 300000), loan('b', 200000, 'active', 150000)])
    expect(text()).toContain('450,000')
    expect(text()).toContain('2 loans')
  })

  it('does not lose an active loan behind a newer pending one', () => {
    cards([loan('a', 300000), loan('b', 110000, 'pending')])
    expect(text()).toContain('300,000')
    expect(text()).toContain('Request pending')
  })

  it('shows what can still be borrowed, not the whole ceiling', () => {
    // 200,000 x 5 = 1,000,000, less 300,000 owed.
    cards([loan('a', 300000)])
    expect(text()).toContain('700,000')
    expect(text()).not.toContain('1,000,000')
  })

  it('says so when a member has reached three loans', () => {
    cards([loan('a', 10000), loan('b', 10000), loan('c', 10000, 'pending')])
    expect(text()).toContain('You have 3 loans in progress')
    expect(text()).not.toContain('970,000')
  })
})

describe('ObligationsCard with several loans', () => {
  it('lists an installment for each loan due this month', () => {
    renderIt(
      <ObligationsCard
        fees={[]}
        loans={[loan('a', 300000), loan('b', 200000)]}
        installments={[installment('i1', 'a', 15000), installment('i2', 'b', 10000)]}
        currentMonthKey="2026-11"
      />,
    )
    expect(screen.getAllByRole('listitem')).toHaveLength(2)
    expect(text()).toContain('300,000')
    expect(text()).toContain('200,000')
  })
})

describe('RepaymentSchedule with several loans', () => {
  it('groups the rows under the loan they belong to', () => {
    renderIt(
      <RepaymentSchedule
        loans={[loan('a', 300000), loan('b', 200000)]}
        installments={[installment('i1', 'a', 15000), installment('i2', 'b', 10000)]}
        currentMonthKey="2026-11"
      />,
    )
    expect(screen.getAllByRole('heading', { level: 3 })).toHaveLength(2)
  })

  it('stays a plain list with one loan', () => {
    renderIt(
      <RepaymentSchedule
        loans={[loan('a', 300000)]}
        installments={[installment('i1', 'a', 15000)]}
        currentMonthKey="2026-11"
      />,
    )
    expect(screen.queryAllByRole('heading', { level: 3 })).toHaveLength(0)
  })
})
