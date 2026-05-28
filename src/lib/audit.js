// Audit log helpers (Phase 2). Admin-only reads of audit_log, joined to profiles
// for actor names. The RLS policy admits only is_admin() so members never see this.

// Fetch the most recent N audit rows + a profile map keyed by actor_id.
export async function getRecentAudit(supabase, limit = 200) {
  const { data, error } = await supabase
    .from('audit_log')
    .select('*')
    .order('at', { ascending: false })
    .limit(limit)
  if (error) throw error

  const actorIds = [...new Set(data.map((r) => r.actor_id).filter(Boolean))]
  let actors = {}
  if (actorIds.length) {
    const { data: profs, error: pErr } = await supabase
      .from('profiles')
      .select('id, full_name')
      .in('id', actorIds)
    if (pErr) throw pErr
    actors = Object.fromEntries(profs.map((p) => [p.id, p.full_name]))
  }
  return { rows: data, actors }
}
