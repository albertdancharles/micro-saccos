// Dependency-free single-series line chart (replaces recharts, which was ~100 kB
// gzipped for these two simple charts). Renders an SVG with dashed gridlines,
// y-axis ticks, thinned x-axis labels, the line + dots, and a hover/touch
// tooltip. It measures its own container so strokes and text stay crisp at any
// width — the parent just gives it a sized box (e.g. `h-56 w-full`).
import { useEffect, useRef, useState } from 'react'

const MARGIN = { top: 8, right: 8, bottom: 22, left: 40 }
const Y_TICKS = 4

export default function LineChart({
  data, // [{ label, value }]
  color = '#059669',
  formatValue = (v) => String(v),
  formatTick = (v) => String(v),
  formatLabel = (l) => l,
  ariaLabel,
}) {
  const wrapRef = useRef(null)
  const [{ w, h }, setSize] = useState({ w: 0, h: 0 })
  const [hover, setHover] = useState(null)

  useEffect(() => {
    const el = wrapRef.current
    if (!el) return
    const ro = new ResizeObserver(([entry]) => {
      const r = entry.contentRect
      setSize({ w: r.width, h: r.height })
    })
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  const iw = Math.max(0, w - MARGIN.left - MARGIN.right)
  const ih = Math.max(0, h - MARGIN.top - MARGIN.bottom)

  const values = data.map((d) => d.value)
  const yMin = Math.min(0, ...values)
  const dataMax = Math.max(0, ...values)
  const yMax = dataMax === yMin ? yMin + 1 : dataMax
  const span = yMax - yMin

  const xAt = (i) =>
    data.length <= 1 ? MARGIN.left + iw / 2 : MARGIN.left + (i / (data.length - 1)) * iw
  const yAt = (v) => MARGIN.top + ih - ((v - yMin) / span) * ih

  const yTicks = Array.from({ length: Y_TICKS + 1 }, (_, i) => yMin + (span * i) / Y_TICKS)
  const labelStep = Math.max(1, Math.ceil(data.length / Math.max(2, Math.floor(iw / 48))))
  const linePath = data.map((d, i) => `${i === 0 ? 'M' : 'L'} ${xAt(i)} ${yAt(d.value)}`).join(' ')

  function pointerAt(clientX) {
    const rect = wrapRef.current?.getBoundingClientRect()
    if (!rect) return
    const px = clientX - rect.left
    let best = 0
    let bestDist = Infinity
    data.forEach((_, i) => {
      const dist = Math.abs(xAt(i) - px)
      if (dist < bestDist) {
        bestDist = dist
        best = i
      }
    })
    setHover(best)
  }

  const point = hover != null ? data[hover] : null
  // Clamp the tooltip inside the chart so the first and last points don't push
  // it off the edge — on a 360px screen it otherwise clips at both ends.
  const tipLeft = point ? Math.min(Math.max(xAt(hover), 52), Math.max(52, w - 52)) : 0
  // Keep it below the top edge when a peak sits near the ceiling.
  const tipTop = point ? Math.max(yAt(point.value) - 8, 34) : 0

  return (
    <div
      ref={wrapRef}
      // pan-y lets a vertical swipe scroll the page as normal while horizontal
      // movement scrubs the chart — without it, trying to scroll past the chart
      // traps the gesture.
      style={{ touchAction: 'pan-y' }}
      className="relative h-full w-full"
      onMouseMove={(e) => pointerAt(e.clientX)}
      onMouseLeave={() => setHover(null)}
      onTouchStart={(e) => pointerAt(e.touches[0].clientX)}
      onTouchMove={(e) => pointerAt(e.touches[0].clientX)}
      // Without these the tooltip stayed pinned after the finger left, so the
      // chart kept showing a reading for a point nobody was touching.
      onTouchEnd={() => setHover(null)}
      onTouchCancel={() => setHover(null)}
    >
      {w > 0 && h > 0 && (
        <svg width={w} height={h} role="img" aria-label={ariaLabel}>
          {yTicks.map((tv, i) => (
            <g key={`y${i}`}>
              <line
                x1={MARGIN.left}
                x2={w - MARGIN.right}
                y1={yAt(tv)}
                y2={yAt(tv)}
                stroke="#f1f5f9"
                strokeDasharray="3 3"
              />
              <text
                x={MARGIN.left - 6}
                y={yAt(tv)}
                textAnchor="end"
                dominantBaseline="middle"
                fontSize="11"
                fill="#94a3b8"
              >
                {formatTick(tv)}
              </text>
            </g>
          ))}

          {data.map((d, i) =>
            i % labelStep === 0 || i === data.length - 1 ? (
              <text
                key={`x${i}`}
                x={xAt(i)}
                y={h - 6}
                textAnchor="middle"
                fontSize="11"
                fill="#94a3b8"
              >
                {formatLabel(d.label)}
              </text>
            ) : null,
          )}

          {point && (
            <line
              x1={xAt(hover)}
              x2={xAt(hover)}
              y1={MARGIN.top}
              y2={MARGIN.top + ih}
              stroke="#cbd5e1"
              strokeDasharray="3 3"
            />
          )}

          <path
            d={linePath}
            fill="none"
            stroke={color}
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          />

          {data.map((d, i) => (
            <circle
              key={`d${i}`}
              cx={xAt(i)}
              cy={yAt(d.value)}
              // The touched point grows and gains a white collar so it stays
              // visible under a fingertip.
              r={hover === i ? 5 : 3}
              fill={color}
              stroke={hover === i ? '#fff' : 'none'}
              strokeWidth={hover === i ? 2 : 0}
            />
          ))}
        </svg>
      )}

      {point && (
        <div
          className="pointer-events-none absolute z-10 -translate-x-1/2 -translate-y-full whitespace-nowrap rounded-lg border border-slate-200 bg-white px-2 py-1 text-xs shadow-pop"
          style={{ left: tipLeft, top: tipTop }}
        >
          <div className="text-slate-500">{formatLabel(point.label)}</div>
          <div className="font-medium text-slate-900 tabular-nums">{formatValue(point.value)}</div>
        </div>
      )}
    </div>
  )
}
