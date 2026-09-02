// Pending self-registrations (migration 018). Single-admin: any admin can approve
// a new sign-up (activating them) or reject it (removing the account). Unlike the
// monetary queues this is not 2-of-N — it mirrors admin-create-member.
import { supabase } from '../../supabaseClient'
import { formatDate } from '../../lib/format'
import { approveMember, rejectPendingMember } from '../../lib/admin'
import { useTwoStepAction } from '../../hooks/useTwoStepAction'
import { useLanguage } from '../../hooks/useLanguage'

function Row({ label, value }) {
  if (!value) return null
  return (
    <div className="flex justify-between gap-3 text-sm">
      <span className="text-slate-500">{label}</span>
      <span className="text-slate-900 text-right break-all">{value}</span>
    </div>
  )
}

function MemberItem({ member, onActioned }) {
  const { t } = useLanguage()
  const { busy, error, handleApprove, handleCancel } = useTwoStepAction({
    onApprove: async () => {
      await approveMember(supabase, member.id)
      onActioned?.()
    },
    onCancel: async () => {
      await rejectPendingMember(supabase, member.id)
      onActioned?.()
    },
    confirmCancel: t('Reject and permanently remove this applicant?'),
    approveError: t('Could not approve the member.'),
    cancelError: t('Could not reject the applicant.'),
  })

  return (
    <div className="rounded-xl border border-slate-200/80 bg-white p-4 space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="font-medium text-slate-900">{member.full_name}</p>
          <p className="text-xs text-slate-500 mt-0.5">
            {t('Applied {date}').replace('{date}', formatDate(member.created_at?.slice(0, 10)))}
          </p>
        </div>
        <span className="inline-flex items-center rounded-full bg-amber-50 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-amber-700 ring-1 ring-inset ring-amber-200">
          {t('pending')}
        </span>
      </div>

      <div className="rounded-lg bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 space-y-1">
        <Row label={t('Email')} value={member.email} />
        <Row label={t('Phone')} value={member.phone_number} />
        <Row label={t('Additional phone')} value={member.secondary_phone} />
        <Row label={t('Residence')} value={member.residence} />
        <Row label={t('National ID (NIDA)')} value={member.national_id} />
        <Row label={t('Next of kin')} value={member.next_of_kin_name} />
        <Row label={t('Next of kin — phone')} value={member.next_of_kin_phone} />
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="flex gap-2">
        <button onClick={handleApprove} disabled={busy} className="btn-primary flex-1">
          {busy ? t('Working…') : t('Approve member')}
        </button>
        <button onClick={handleCancel} disabled={busy} className="btn-danger">
          {t('Reject')}
        </button>
      </div>
    </div>
  )
}

export default function PendingMembersQueue({ pendingMembers, onActioned }) {
  const { t } = useLanguage()
  if (!pendingMembers || pendingMembers.length === 0) return null

  return (
    <section className="rounded-2xl border border-amber-200/70 bg-white p-4 sm:p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <h2 className="text-[13px] font-semibold tracking-tight text-amber-700 mb-3">
        {t('Pending registrations ({n})').replace('{n}', pendingMembers.length)}
      </h2>
      <div className="space-y-3">
        {pendingMembers.map((m) => (
          <MemberItem key={m.id} member={m} onActioned={onActioned} />
        ))}
      </div>
    </section>
  )
}
