// Increase / decrease segmented toggle for delta-style edits (savings & pool
// edit modals). Emerald = increase, red = decrease. Extracted so both modals
// share one source of truth.
import { useLanguage } from '../../hooks/useLanguage'

export default function DirectionToggle({ direction, onChange }) {
  const { t } = useLanguage()
  const opts = [
    {
      key: 'increase',
      label: t('Increase'),
      active: 'border-emerald-500 bg-emerald-50 text-emerald-700 ring-emerald-200',
    },
    {
      key: 'decrease',
      label: t('Decrease'),
      active: 'border-red-500 bg-red-50 text-red-700 ring-red-200',
    },
  ]
  return (
    <div className="grid grid-cols-2 gap-2">
      {opts.map((o) => (
        <button
          key={o.key}
          type="button"
          onClick={() => onChange(o.key)}
          aria-pressed={direction === o.key}
          className={`rounded-xl border px-3 py-2.5 text-sm font-medium transition-all duration-150 ${
            direction === o.key
              ? `${o.active} ring-1`
              : 'border-slate-200 text-slate-600 hover:border-slate-300'
          }`}
        >
          {o.label}
        </button>
      ))}
    </div>
  )
}
