// Share-out arithmetic — a pure mirror of preview_cycle_close (migration 024), so
// the close wizard can show the split and totals without a round-trip, and so the
// rounding rule is unit-testable.
//
// TIME-WEIGHTED BASIS. A member's share is proportional to their capital measured
// at every month-end of the cycle and summed (member-months), not to their closing
// balance — otherwise a member who deposits in the last month takes the same cut as
// one who carried the group all year.
//
// LARGEST REMAINDER. Every share is floored to whole shillings, then the leftover
// shillings go one each to the largest fractional parts. The shares therefore sum
// EXACTLY to the pot: no stray shilling, and nobody is quietly rounded down twice.

// rows: [{ member_id, basis, closing_capital }]
// Returns the same rows with earnings / capital / total, largest-remainder applied.
export function allocateShares(rows, netEarnings, mode = 'earnings_only') {
  const list = rows || []
  const totalBasis = list.reduce((s, r) => s + Number(r.basis || 0), 0)
  // A loss is absorbed by the pool, not billed back to members, so the pot floors
  // at zero — matching `floor(greatest(net, 0))` in the SQL. With no basis at all
  // nobody has a proportional claim, so the pot stays in the pool rather than the
  // remainder pass handing shillings to members who contributed nothing.
  const pot = totalBasis > 0 ? Math.floor(Math.max(Number(netEarnings) || 0, 0)) : 0

  const exact = list.map((r) => ({
    ...r,
    exactShare: totalBasis > 0 ? (pot * Number(r.basis || 0)) / totalBasis : 0,
    ratio: totalBasis > 0 ? Number(r.basis || 0) / totalBasis : 0,
  }))

  const floored = exact.map((r) => ({ ...r, earnings: Math.floor(r.exactShare) }))
  let leftover = pot - floored.reduce((s, r) => s + r.earnings, 0)

  // Ties break on member_id so the SQL and JS hand the same shilling to the same
  // member — a preview that disagrees with the committed split would be worse than
  // no preview at all.
  const order = [...floored].sort((a, b) => {
    const fa = a.exactShare - Math.floor(a.exactShare)
    const fb = b.exactShare - Math.floor(b.exactShare)
    if (fb !== fa) return fb - fa
    return String(a.member_id).localeCompare(String(b.member_id))
  })
  for (const r of order) {
    if (leftover <= 0) break
    r.earnings += 1
    leftover -= 1
  }

  return floored.map((r) => {
    const capital = mode === 'full_shareout' ? Math.max(0, Number(r.closing_capital || 0)) : 0
    return {
      member_id: r.member_id,
      full_name: r.full_name,
      basis: Number(r.basis || 0),
      ratio: r.ratio,
      earnings: r.earnings,
      capital,
      total: r.earnings + capital,
    }
  })
}

export function shareOutTotals(allocated) {
  return (allocated || []).reduce(
    (acc, r) => ({
      earnings: acc.earnings + r.earnings,
      capital: acc.capital + r.capital,
      total: acc.total + r.total,
    }),
    { earnings: 0, capital: 0, total: 0 },
  )
}
