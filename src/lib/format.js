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

export const formatDate = (s) => (s ? dayFmt.format(new Date(`${s}T00:00:00Z`)) : '') // "30 Jun 2026"
export const formatMonth = (s) => (s ? monthFmt.format(new Date(`${s}T00:00:00Z`)) : '') // "Jun 2026"
