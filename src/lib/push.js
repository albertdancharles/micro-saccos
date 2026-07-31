// Notification channels (migration 026).
//
// In-app notifications only reach a member who opens the PWA — which is exactly
// the member who isn't opening it. These helpers let each member choose how the
// group reaches them: an SMS to their phone (opt-in by default, because it is the
// only channel that reaches a feature phone) and/or a browser push.

export async function getNotificationPrefs(supabase, memberId) {
  const { data, error } = await supabase
    .from('profiles')
    .select('sms_opt_in, push_enabled, phone_e164, preferred_language')
    .eq('id', memberId)
    .single()
  if (error) throw error
  return data
}

export async function updateNotificationPrefs(supabase, { smsOptIn, pushEnabled, language }) {
  const { error } = await supabase.rpc('update_notification_prefs', {
    p_sms_opt_in: smsOptIn,
    p_push_enabled: pushEnabled,
    p_language: language ?? null,
  })
  if (error) throw error
}

export const pushSupported = () =>
  typeof window !== 'undefined' && 'serviceWorker' in navigator && 'PushManager' in window

// The VAPID public key is public by definition — it's the key the browser encrypts
// to. The private half stays in the Edge Function's secrets.
const VAPID_PUBLIC_KEY = import.meta.env.VITE_VAPID_PUBLIC_KEY || ''

// Push wants a Uint8Array, and VAPID keys are distributed base64url.
function urlBase64ToUint8Array(base64String) {
  const padding = '='.repeat((4 - (base64String.length % 4)) % 4)
  const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/')
  const raw = atob(base64)
  return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)))
}

// Subscribes this device and stores the endpoint. Returns false (rather than
// throwing) when push simply isn't available or the member declines — that is a
// normal outcome, not an error worth showing as one.
export async function subscribeToPush(supabase, memberId) {
  if (!pushSupported() || !VAPID_PUBLIC_KEY) return false

  const permission = await Notification.requestPermission()
  if (permission !== 'granted') return false

  const registration = await navigator.serviceWorker.ready
  const existing = await registration.pushManager.getSubscription()
  const sub =
    existing ||
    (await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY),
    }))

  const json = sub.toJSON()
  const { error } = await supabase.from('push_subscriptions').upsert(
    {
      member_id: memberId,
      endpoint: json.endpoint,
      p256dh: json.keys?.p256dh,
      auth: json.keys?.auth,
    },
    { onConflict: 'endpoint' },
  )
  if (error) throw error
  return true
}

export async function unsubscribeFromPush(supabase) {
  if (!pushSupported()) return
  const registration = await navigator.serviceWorker.ready
  const sub = await registration.pushManager.getSubscription()
  if (!sub) return
  const endpoint = sub.endpoint
  await sub.unsubscribe()
  await supabase.from('push_subscriptions').delete().eq('endpoint', endpoint)
}
