// The group's financial rules at a glance, with a button to propose a change
// (migration 020). Read-only for everyone; only admins see the propose button, and
// any change still needs two other admins to approve.
import { useState } from 'react'
import { formatTZS } from '../../lib/format'
import { formatSettingValue } from '../../lib/settings'
import { useLanguage } from '../../hooks/useLanguage'
import RequestSettingChangeModal from './RequestSettingChangeModal'

export default function SettingsPanel({ rows, onChanged }) {
  const { t } = useLanguage()
  const [open, setOpen] = useState(false)

  // 020 not applied yet (or unreadable) — the dashboard still works on the seeded
  // defaults, so say nothing rather than render an empty card.
  if (!rows || rows.length === 0) return null

  return (
    <section className="rounded-2xl border border-slate-200/80 bg-white p-5 shadow-[0_1px_2px_-1px_rgba(15,23,42,0.04),0_1px_3px_rgba(15,23,42,0.04)]">
      <div className="flex items-center justify-between mb-3">
        <h2 className="text-[13px] font-semibold tracking-tight text-slate-700">
          {t('Group rules')}
        </h2>
        <button onClick={() => setOpen(true)} className="btn-secondary text-xs px-3 py-1.5">
          {t('Propose change')}
        </button>
      </div>

      <dl className="divide-y divide-slate-100">
        {rows.map((r) => (
          <div key={r.key} className="flex items-center justify-between py-2 text-sm">
            <dt className="text-slate-500">{t(r.label)}</dt>
            <dd className="font-medium text-slate-900 tabular-nums">
              {formatSettingValue(r.key, r.value, formatTZS)}
            </dd>
          </div>
        ))}
      </dl>

      <p className="mt-3 text-xs text-slate-500">
        {t('Changing a rule needs two admin approvals and applies to future fees and loans only.')}
      </p>

      <RequestSettingChangeModal
        open={open}
        onClose={() => setOpen(false)}
        rows={rows}
        onSubmitted={onChanged}
      />
    </section>
  )
}
