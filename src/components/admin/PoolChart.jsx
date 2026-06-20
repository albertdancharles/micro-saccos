// Group pool over time (admin only). Each point is end-of-month pool balance.
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
import { getPoolHistory } from '../../lib/charts'
import { formatTZS, formatMonth } from '../../lib/format'
import { useLanguage } from '../../hooks/useLanguage'

function fmtMonthShort(s) {
  // 'YYYY-MM' → 'Jun 26'
  if (!s) return ''
  return formatMonth(`${s}-01`).replace(/\s/, ' ')
}

export default function PoolChart() {
  const { t } = useLanguage()
  const [data, setData] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const load = useCallback(async () => {
    if (!supabase) return
    try {
      setData(await getPoolHistory(supabase))
      setError(null)
    } catch (err) {
      console.error('PoolChart load failed', err)
      setError(err?.message || t('Could not load the chart.'))
    } finally {
      setLoading(false)
    }
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  return (
    <section className="rounded-2xl border border-slate-200/70 bg-white p-4 shadow-card">
      <h2 className="text-sm font-semibold text-slate-900 mb-3">{t('Group pool over time')}</h2>
      {loading ? (
        <p className="text-sm text-slate-400 py-8 text-center">{t('Loading…')}</p>
      ) : error ? (
        <p className="text-sm text-red-600">{error}</p>
      ) : data.length === 0 ? (
        <p className="text-sm text-slate-400 py-8 text-center">
          {t('No history yet. Approve a payment to see the chart fill in.')}
        </p>
      ) : (
        <div className="h-56 w-full">
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
                formatter={(v) => [formatTZS(v), t('Pool')]}
              />
              <Line
                type="monotone"
                dataKey="pool"
                stroke="#059669"
                strokeWidth={2}
                dot={{ r: 3, fill: '#059669' }}
                isAnimationActive={false}
              />
            </LineChart>
          </ResponsiveContainer>
        </div>
      )}
    </section>
  )
}
