import { createClient } from '@supabase/supabase-js'

// Local dev points at the `supabase start` stack; production uses the hosted
// project's keys (set in Vercel). See build plan §12. Never put the
// service-role key here — anon key only.
const url = import.meta.env.VITE_SUPABASE_URL
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!url || !anonKey) {
  // Skeleton stage: env not wired yet. Don't throw, just warn.
  console.warn('Supabase env vars missing — copy .env.example to .env.local once the local stack is running.')
}

export const supabase = url && anonKey ? createClient(url, anonKey) : null
