// Approvals queue (build plan §9). Two tabs: pending loans and pending payments.
import { useState } from 'react'
import LoanQueueItem from './LoanQueueItem'
import PaymentQueueItem from './PaymentQueueItem'

function TabButton({ active, onClick, children }) {
  return (
    <button
      onClick={onClick}
      className={`flex-1 rounded-lg py-2 text-sm font-medium ${
        active ? 'bg-white text-gray-900 shadow-sm' : 'text-gray-500'
      }`}
    >
      {children}
    </button>
  )
}

export default function ApprovalsQueue({ pendingLoans, pendingPayments, onActioned }) {
  const [tab, setTab] = useState('payments')

  return (
    <section className="rounded-2xl border border-gray-100 bg-white p-4">
      <h2 className="text-sm font-semibold text-gray-900 mb-3">Approvals</h2>

      <div className="flex gap-1 rounded-xl bg-gray-100 p-1 mb-4">
        <TabButton active={tab === 'payments'} onClick={() => setTab('payments')}>
          Payments ({pendingPayments.length})
        </TabButton>
        <TabButton active={tab === 'loans'} onClick={() => setTab('loans')}>
          Loans ({pendingLoans.length})
        </TabButton>
      </div>

      {tab === 'payments' ? (
        pendingPayments.length ? (
          <div className="space-y-3">
            {pendingPayments.map((s) => (
              <PaymentQueueItem key={s.id} submission={s} onActioned={onActioned} />
            ))}
          </div>
        ) : (
          <p className="text-sm text-gray-400 text-center py-6">No payments awaiting review. 🎉</p>
        )
      ) : pendingLoans.length ? (
        <div className="space-y-3">
          {pendingLoans.map((l) => (
            <LoanQueueItem key={l.id} loan={l} onActioned={onActioned} />
          ))}
        </div>
      ) : (
        <p className="text-sm text-gray-400 text-center py-6">No loan requests awaiting review.</p>
      )}
    </section>
  )
}
