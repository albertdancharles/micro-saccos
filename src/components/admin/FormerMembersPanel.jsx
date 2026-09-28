// Members who have left the group (migration 025's exit settlement).
//
// Exit deactivates the profile but KEEPS every fee, loan and repayment, so past
// cycles still reconcile. That left them nowhere on this dashboard: the member
// grid shows active members only, and the one place inactive profiles did appear
// was the applicant queue, which offered to "approve" or permanently delete them.
//
// So they get their own panel, and it is deliberately inert — no approve, no
// reject, no menu. Reinstating someone who was settled and paid out is not a
// one-tap decision, and removing them is the 2-of-N deletion flow, not this.
import { useLanguage } from '../../hooks/useLanguage'

export default function FormerMembersPanel({ formerMembers }) {
  const { t } = useLanguage()
  if (!formerMembers || formerMembers.length === 0) return null

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-4 sm:p-5 shadow-card">
      <div className="mb-1 flex items-baseline gap-2">
        <h2 className="text-[13px] font-semibold tracking-tight text-slate-900">
          {t('Former members')}
        </h2>
        <span className="text-xs text-slate-400 tabular-nums">
          {t('{n} total').replace('{n}', formerMembers.length)}
        </span>
      </div>
      <p className="mb-3 text-xs text-slate-500">
        {t('Settled and no longer active. Their records are kept so past cycles still add up.')}
      </p>

      <ul className="divide-y divide-slate-100">
        {formerMembers.map((m) => (
          <li key={m.id} className="flex items-center justify-between gap-3 py-2.5">
            <span className="min-w-0 truncate text-sm text-slate-600">{m.full_name}</span>
            {/* No figure here on purpose. An exit settles the member's whole
                balance, so every one of these reads "TSh 0" — technically true and
                worth nothing, and easy to misread as a member sitting at zero
                rather than one who was paid out and left. */}
            <span className="shrink-0 rounded-full bg-slate-100 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-slate-500 ring-1 ring-inset ring-slate-200">
              {t('settled')}
            </span>
          </li>
        ))}
      </ul>
    </section>
  )
}
