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

function fmtMonthShort(s) {
  // 'YYYY-MM' → 'Jun 26'
  if (!s) return ''
  return formatMonth(`${s}-01`).replace(/\s/, ' ')
}

export default function PoolChart() {
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
      setError(err?.message || 'Could not load the chart.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  return (
    <section className="rounded-2xl border border-gray-100 bg-white p-4">
      <h2 className="text-sm font-semibold text-gray-900 mb-3">Group pool over time</h2>
      {loading ? (
        <p className="text-sm text-gray-400 py-8 text-center">Loading…</p>
      ) : error ? (
        <p className="text-sm text-red-600">{error}</p>
      ) : data.length === 0 ? (
        <p className="text-sm text-gray-400 py-8 text-center">No history yet. Approve a payment to see the chart fill in.</p>
      ) : (
        <div className="h-56 w-full">
          <ResponsiveContainer width="100%" height="100%">
            <LineChart data={data} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
              <CartesianGrid strokeDasharray="3 3" stroke="#f3f4f6" />
              <XAxis
                dataKey="month"
                tickFormatter={fmtMonthShort}
                tick={{ fontSize: 11, fill: '#9ca3af' }}
              />
              <YAxis
                tickFormatter={(v) => `${Math.round(v / 1000)}k`}
                tick={{ fontSize: 11, fill: '#9ca3af' }}
                width={36}
              />
              <Tooltip
                contentStyle={{ fontSize: 12, borderRadius: 8, borderColor: '#e5e7eb' }}
                labelFormatter={fmtMonthShort}
                formatter={(v) => [formatTZS(v), 'Pool']}
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
