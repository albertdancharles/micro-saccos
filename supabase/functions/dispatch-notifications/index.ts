// supabase/functions/dispatch-notifications/index.ts
//
// Drains the `notification_deliveries` outbox (migration 026). Everything that
// decides WHAT to send lives in SQL; this function only knows HOW to put a message
// on a wire, which is the one thing Postgres cannot do.
//
// Channels:
//   sms       Africa's Talking — reaches feature phones, which is most of the group
//   whatsapp  Twilio WhatsApp Business sender
//   push      Web Push (VAPID); left unimplemented here because signing a VAPID JWT
//             needs a crypto dependency, and SMS is what actually reaches this
//             group. Push rows are marked 'skipped' with a clear reason rather than
//             retried forever — see the note at the bottom.
//
// Secrets (Supabase dashboard → Edge Functions → Secrets; never in .env.local):
//   AT_API_KEY, AT_USERNAME, AT_SENDER_ID            — Africa's Talking
//   TWILIO_SID, TWILIO_TOKEN, TWILIO_WHATSAPP_FROM   — Twilio (optional)
//   DISPATCH_SECRET                                  — shared secret for the caller
//
// Invoke on a schedule (pg_cron + pg_net, every 15 minutes) or manually.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const MAX_ATTEMPTS = 3
const BATCH = 50

type Delivery = {
  id: string
  channel: 'push' | 'sms' | 'whatsapp'
  address: string
  title: string
  body: string | null
  attempts: number
}

// One SMS is ~160 characters and each extra segment is billed again, so the title
// and body are joined and trimmed to a single segment.
function composeSms(d: Delivery): string {
  const text = d.body ? `${d.title}: ${d.body}` : d.title
  return text.length <= 160 ? text : `${text.slice(0, 157)}...`
}

async function sendSms(to: string, text: string): Promise<void> {
  const apiKey = Deno.env.get('AT_API_KEY')
  const username = Deno.env.get('AT_USERNAME')
  if (!apiKey || !username) throw new Error('SMS is not configured (AT_API_KEY / AT_USERNAME)')

  const form = new URLSearchParams({ username, to, message: text })
  const sender = Deno.env.get('AT_SENDER_ID')
  if (sender) form.set('from', sender)

  const res = await fetch('https://api.africastalking.com/version1/messaging', {
    method: 'POST',
    headers: {
      apiKey,
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json',
    },
    body: form,
  })
  if (!res.ok) throw new Error(`Africa's Talking ${res.status}: ${await res.text()}`)

  // A 200 does not mean delivered — check the per-recipient status too.
  const json = await res.json()
  const recipient = json?.SMSMessageData?.Recipients?.[0]
  if (recipient && recipient.status !== 'Success') {
    throw new Error(`Africa's Talking rejected ${to}: ${recipient.status}`)
  }
}

async function sendWhatsApp(to: string, text: string): Promise<void> {
  const sid = Deno.env.get('TWILIO_SID')
  const token = Deno.env.get('TWILIO_TOKEN')
  const from = Deno.env.get('TWILIO_WHATSAPP_FROM')
  if (!sid || !token || !from) throw new Error('WhatsApp is not configured')

  const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
    method: 'POST',
    headers: {
      Authorization: `Basic ${btoa(`${sid}:${token}`)}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({
      From: `whatsapp:${from}`,
      To: `whatsapp:${to}`,
      Body: text,
    }),
  })
  if (!res.ok) throw new Error(`Twilio ${res.status}: ${await res.text()}`)
}

Deno.serve(async (req) => {
  // The outbox holds phone numbers, so this endpoint is not open to the world.
  const secret = Deno.env.get('DISPATCH_SECRET')
  if (secret && req.headers.get('x-dispatch-secret') !== secret) {
    return new Response('Forbidden', { status: 403 })
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  const { data: queue, error } = await supabase
    .from('notification_deliveries')
    .select('id, channel, address, title, body, attempts')
    .eq('status', 'queued')
    .order('created_at', { ascending: true })
    .limit(BATCH)

  if (error) return new Response(JSON.stringify({ error }), { status: 500 })
  if (!queue?.length) return new Response(JSON.stringify({ sent: 0, failed: 0, skipped: 0 }))

  let sent = 0
  let failed = 0
  let skipped = 0

  for (const d of queue as Delivery[]) {
    try {
      if (d.channel === 'sms') {
        await sendSms(d.address, composeSms(d))
      } else if (d.channel === 'whatsapp') {
        await sendWhatsApp(d.address, d.body ? `*${d.title}*\n${d.body}` : d.title)
      } else {
        // Web Push needs a signed VAPID JWT; not wired up yet. Skipped rather than
        // failed so it never burns retries, and the reason is visible in the table.
        await supabase
          .from('notification_deliveries')
          .update({ status: 'skipped', last_error: 'push dispatch not implemented' })
          .eq('id', d.id)
        skipped++
        continue
      }

      await supabase
        .from('notification_deliveries')
        .update({ status: 'sent', sent_at: new Date().toISOString(), attempts: d.attempts + 1 })
        .eq('id', d.id)
      sent++
    } catch (err) {
      const attempts = d.attempts + 1
      // Give up after MAX_ATTEMPTS: a number that is wrong today will still be
      // wrong tomorrow, and each retry costs money.
      await supabase
        .from('notification_deliveries')
        .update({
          status: attempts >= MAX_ATTEMPTS ? 'failed' : 'queued',
          attempts,
          last_error: String(err instanceof Error ? err.message : err).slice(0, 500),
        })
        .eq('id', d.id)
      failed++
    }
  }

  return new Response(JSON.stringify({ sent, failed, skipped }), {
    headers: { 'Content-Type': 'application/json' },
  })
})
