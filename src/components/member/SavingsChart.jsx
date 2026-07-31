// My savings over time (member). Monthly cumulative, scoped to this member.
import { useCallback, useEffect, useState } from 'react'
import LineChart from '../ui/LineChart'
import { supabase } from '../../supabaseClient'
import { useAuth } from '../../hooks/useAuth'
import { getSavingsHistory } from '../../lib/charts'
import { formatTZS, formatMonth } from '../../lib/format'
import { useLanguage } from '../../hooks/useLanguage'

const fmtMonthShort = (s) => (s ? formatMonth(`${s}-01`) : '')

export default function SavingsChart({ memberId: overrideMemberId = null }) {
  const { user } = useAuth()
  const { t } = useLanguage()
  const memberId = overrideMemberId ?? user?.id ?? null
  const [data, setData] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const load = useCallback(async () => {
    if (!supabase || !memberId) return
    try {
      setData(await getSavingsHistory(supabase, memberId))
      setError(null)
    } catch (err) {
      console.error('SavingsChart load failed', err)
      setError(err?.message || 'Could not load the chart.')
    } finally {
      setLoading(false)
    }
  }, [memberId])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  if (loading || data.length === 0) {
    // Skip rendering until there's something interesting — a member with no
    // savings yet doesn't need an empty chart cluttering their dashboard.
    return null
  }
  if (error) {
    return <p className="text-sm text-red-600">{error}</p>
  }

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-4 shadow-card">
      <h2 className="text-sm font-semibold text-slate-900 mb-3">{t('My savings over time')}</h2>
      <div className="h-48 w-full">
        <LineChart
          data={data.map((d) => ({ label: d.month, value: d.savings }))}
          color="#0ea5e9"
          formatValue={formatTZS}
          formatTick={(v) => `${Math.round(v / 1000)}k`}
          formatLabel={fmtMonthShort}
          ariaLabel={t('My savings over time')}
        />
      </div>
    </section>
  )
}
