// Loading placeholder for the two dashboards.
//
// Both used to render a centred "Loading…" on an otherwise empty page. On the
// 3G connections this group is on that is several seconds of a screen that gives
// no clue what is coming, and when the data lands the whole layout appears at
// once and shifts under the thumb. The shapes here match what actually replaces
// them — a hero card, a 2x2 of stats, then stacked sections — so the page keeps
// its geometry and the arrival reads as filling in rather than jumping.
//
// aria-busy + a live label keep it honest for screen readers, which otherwise
// get a handful of meaningless empty boxes.
export default function DashboardSkeleton({ label, wide = false }) {
  return (
    <div className="space-y-4" role="status" aria-busy="true" aria-live="polite">
      <span className="sr-only">{label}</span>

      <div className="grid grid-cols-2 gap-3" aria-hidden="true">
        <div className="skeleton col-span-2 h-28 rounded-2xl" />
        <div className="skeleton h-24 rounded-2xl" />
        <div className="skeleton h-24 rounded-2xl" />
        <div className="skeleton h-24 rounded-2xl" />
        <div className="skeleton h-24 rounded-2xl" />
      </div>

      <div className="skeleton h-12 rounded-xl" aria-hidden="true" />
      <div className="skeleton h-44 rounded-2xl" aria-hidden="true" />
      {wide && <div className="skeleton h-64 rounded-2xl" aria-hidden="true" />}
    </div>
  )
}
