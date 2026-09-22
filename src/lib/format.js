// Single source of TZS formatting (build plan §8f). Whole shillings, no cents.
const fmt = new Intl.NumberFormat('sw-TZ', {
  style: 'currency',
  currency: 'TZS',
  maximumFractionDigits: 0,
})

export const formatTZS = (n) => fmt.format(Number(n) || 0) // e.g. "TSh 10,000"

// Dates from the DB are 'YYYY-MM-DD' (already East Africa Time). Format in UTC so the
// displayed day never drifts across the browser's timezone.
const dayFmt = new Intl.DateTimeFormat('en-GB', {
  day: 'numeric',
  month: 'short',
  year: 'numeric',
  timeZone: 'UTC',
})
const monthFmt = new Intl.DateTimeFormat('en-GB', { month: 'short', year: 'numeric', timeZone: 'UTC' })

// Accepts either a 'YYYY-MM-DD' date column or a full timestamptz
// ('2026-06-30T08:14:32.123456+00:00') — the DB hands us both, and appending the
// time to a value that already carried one produced an Invalid Date. Intl throws
// a RangeError on those, so a single bad row used to take the whole page down
// via the error boundary rather than blanking one line. Unparseable input now
// formats as ''; a date is a label, never a reason to lose the screen.
const utcMidnight = (s) => new Date(`${String(s).slice(0, 10)}T00:00:00Z`)

const formatUTC = (formatter, s) => {
  if (!s) return ''
  const d = utcMidnight(s)
  return Number.isNaN(d.getTime()) ? '' : formatter.format(d)
}

export const formatDate = (s) => formatUTC(dayFmt, s) // "30 Jun 2026"
export const formatMonth = (s) => formatUTC(monthFmt, s) // "Jun 2026"
