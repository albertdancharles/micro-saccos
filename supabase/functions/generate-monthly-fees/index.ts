// supabase/functions/generate-monthly-fees/index.ts
// Primary monthly-fee generator (build plan §8d). Runs on a pg_cron schedule on the
// 1st. ensure_current_fees() is the on-load safety net for when cron is skipped.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

Deno.serve(async () => {
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  // Period = 1st of the current month in East Africa Time (UTC+3), not UTC, so a run
  // just after midnight EAT on the 1st doesn't fall back into the previous month.
  const eat = new Date(Date.now() + 3 * 60 * 60 * 1000)
  const period = `${eat.getUTCFullYear()}-${String(eat.getUTCMonth() + 1).padStart(2, '0')}-01`

  const { data: members } = await supabase
    .from('profiles')
    .select('id')
    .eq('is_active', true) // all active profiles, admin included

  if (!members?.length) return new Response('No active members')

  const rows = members.map((m) => ({
    member_id: m.id,
    period,
    amount: 10000,
    status: 'pending',
  }))

  // ignoreDuplicates → idempotent, safe to re-run.
  const { error } = await supabase
    .from('monthly_fees')
    .upsert(rows, { onConflict: 'member_id,period', ignoreDuplicates: true })

  if (error) return new Response(JSON.stringify({ error }), { status: 500 })
  return new Response(JSON.stringify({ generated: rows.length, period }))
})
