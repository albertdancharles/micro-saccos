// Profile helpers. Member self-service writes go through SECURITY DEFINER RPCs
// rather than direct table updates, so RLS on `profiles` can stay strict (admin-
// only blanket UPDATE) while letting members maintain their own info.
import { supabase } from '../supabaseClient'

export async function updateOwnPhone(phone) {
  const { error } = await supabase.rpc('update_own_phone', { p_phone: phone })
  if (error) throw error
}
