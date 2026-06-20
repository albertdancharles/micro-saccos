// My savings over time (member). Monthly cumulative, scoped to this member.
import { useCallback, useEffect, useState } from 'react'
import {
  CartesianGrid,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
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
        <ResponsiveContainer width="100%" height="100%">
          <LineChart data={data} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
            <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
            <XAxis
              dataKey="month"
              tickFormatter={fmtMonthShort}
              tick={{ fontSize: 11, fill: '#94a3b8' }}
            />
            <YAxis
              tickFormatter={(v) => `${Math.round(v / 1000)}k`}
              tick={{ fontSize: 11, fill: '#94a3b8' }}
              width={36}
            />
            <Tooltip
              contentStyle={{ fontSize: 12, borderRadius: 8, borderColor: '#e2e8f0' }}
              labelFormatter={fmtMonthShort}
              formatter={(v) => [formatTZS(v), t('Savings')]}
            />
            <Line
              type="monotone"
              dataKey="savings"
              stroke="#0ea5e9"
              strokeWidth={2}
              dot={{ r: 3, fill: '#0ea5e9' }}
              isAnimationActive={false}
            />
          </LineChart>
        </ResponsiveContainer>
      </div>
    </section>
  )
}
