// supabase/functions/dispatch-notifications/index.ts
//
// Drains the `notification_deliveries` outbox (migration 026). Everything that
// decides WHAT to send lives in SQL; this function only knows HOW to put a message
// on a wire, which is the one thing Postgres cannot do.
//
// Channels:
//   sms       Beem Africa — reaches feature phones, which is most of the group
//   whatsapp  Twilio WhatsApp Business sender (optional)
//   push      Web Push (VAPID); not implemented — rows are marked 'skipped' with a
//             reason rather than retried forever.
//
// Secrets (Dashboard → Edge Functions → Secrets; never in .env.local):
//   BEEM_API_KEY, BEEM_SECRET_KEY, BEEM_SENDER_ID          — Beem Africa SMS
//   TWILIO_SID, TWILIO_TOKEN, TWILIO_WHATSAPP_FROM         — WhatsApp (optional)
//   DISPATCH_SECRET                                        — required; the caller
//                                                            sends it as x-dispatch-secret
//   DISPATCH_MAX_AGE_HOURS                                 — optional, default 48
//
// Deploy with --no-verify-jwt: DISPATCH_SECRET is the real gate (the anon key is
// public, so a JWT check would not actually keep anyone out).
//
// Request body (all optional):
//   { "check": true }     report configuration + queue depth, send nothing
//   { "dry_run": true }   report exactly what WOULD go out, send nothing
//   { "limit": 10 }       cap this batch (default 50)
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const MAX_ATTEMPTS = 3
const BATCH = 50

// Reminders are perishable. A "due in 3 days" text delivered a fortnight late is
// worse than no text: it costs money and tells the member something untrue. Rows
// older than this are retired unsent instead of being delivered.
const MAX_AGE_HOURS = Number(Deno.env.get('DISPATCH_MAX_AGE_HOURS') ?? 48)

const BEEM_URL = Deno.env.get('BEEM_API_URL') ?? 'https://apisms.beem.africa/v1/send'

type Delivery = {
  id: string
  channel: 'push' | 'sms' | 'whatsapp'
  address: string
  title: string
  body: string | null
  attempts: number
}

// A bad phone number is still bad tomorrow, and a malformed request still
// malformed — retrying either just spends money to fail again.
class PermanentError extends Error {}

// Not this message's fault: no credit, bad credentials, provider down. The whole
// batch is blocked, so stop early and leave the rows queued WITHOUT burning an
// attempt — otherwise an empty Beem account quietly destroys a day of reminders.
class BlockedError extends Error {}

// One SMS is ~160 characters and each extra segment is billed again, so the title
// and body are joined and trimmed to a single segment.
function composeSms(d: Delivery): string {
  const text = d.body ? `${d.title}: ${d.body}` : d.title
  return text.length <= 160 ? text : `${text.slice(0, 157)}...`
}

async function sendSms(to: string, text: string): Promise<void> {
  const apiKey = Deno.env.get('BEEM_API_KEY')
  const secretKey = Deno.env.get('BEEM_SECRET_KEY')
  if (!apiKey || !secretKey) {
    throw new BlockedError('SMS is not configured (BEEM_API_KEY / BEEM_SECRET_KEY)')
  }

  // We store E.164 (+255712345678); Beem wants a bare MSISDN (255712345678).
  const dest = to.replace(/[^0-9]/g, '')
  if (dest.length < 9) throw new PermanentError(`Not a usable number: ${to}`)

  const res = await fetch(BEEM_URL, {
    method: 'POST',
    headers: {
      Authorization: `Basic ${btoa(`${apiKey}:${secretKey}`)}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify({
      source_addr: Deno.env.get('BEEM_SENDER_ID') || 'INFO',
      schedule_time: '',
      encoding: 0,
      message: text,
      recipients: [{ recipient_id: 1, dest_addr: dest }],
    }),
  })

  const raw = (await res.text()).slice(0, 300)
  if (res.status === 401 || res.status === 403) {
    throw new BlockedError(`Beem rejected the credentials (${res.status})`)
  }
  if (res.status >= 500) throw new Error(`Beem ${res.status}: ${raw}`)
  if (res.status === 400) throw new PermanentError(`Beem 400: ${raw}`)

  let json: Record<string, unknown>
  try {
    json = JSON.parse(raw)
  } catch {
    throw new Error(`Beem returned non-JSON: ${raw}`)
  }

  // HTTP 200 does not mean accepted — Beem reports the real outcome in `code`.
  const code = Number(json.code)
  if (json.successful === true && code === 100) return

  const msg = String(json.message ?? raw)
  if (code === 102) throw new BlockedError('Beem: insufficient balance — top up to resume reminders')
  if (code === 101 || code === 104) throw new PermanentError(`Beem ${code}: ${msg}`)
  throw new Error(`Beem ${code || res.status}: ${msg}`)
}

async function sendWhatsApp(to: string, text: string): Promise<void> {
  const sid = Deno.env.get('TWILIO_SID')
  const token = Deno.env.get('TWILIO_TOKEN')
  const from = Deno.env.get('TWILIO_WHATSAPP_FROM')
  if (!sid || !token || !from) throw new BlockedError('WhatsApp is not configured')

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
  if (res.status === 401) throw new BlockedError('Twilio rejected the credentials (401)')
  if (!res.ok) throw new Error(`Twilio ${res.status}: ${(await res.text()).slice(0, 200)}`)
}

Deno.serve(async (req) => {
  // The outbox holds phone numbers and this endpoint spends money, so it is closed
  // unless a secret is configured AND matches. Missing secret = closed, not open.
  const secret = Deno.env.get('DISPATCH_SECRET')
  if (!secret) {
    return new Response(JSON.stringify({ error: 'DISPATCH_SECRET is not set; refusing to run' }), {
      status: 503,
      headers: { 'Content-Type': 'application/json' },
    })
  }
  if (req.headers.get('x-dispatch-secret') !== secret) {
    return new Response('Forbidden', { status: 403 })
  }

  let opts: { check?: boolean; dry_run?: boolean; limit?: number } = {}
  try {
    opts = await req.json()
  } catch {
    /* no body is the normal cron case */
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  // Which providers are actually wired up. Presence only — never the values.
  const configured = {
    sms: !!(Deno.env.get('BEEM_API_KEY') && Deno.env.get('BEEM_SECRET_KEY')),
    sender_id: Deno.env.get('BEEM_SENDER_ID') || 'INFO',
    whatsapp: !!(
      Deno.env.get('TWILIO_SID') &&
      Deno.env.get('TWILIO_TOKEN') &&
      Deno.env.get('TWILIO_WHATSAPP_FROM')
    ),
    push: false,
    max_age_hours: MAX_AGE_HOURS,
  }

  if (opts.check) {
    const { count } = await supabase
      .from('notification_deliveries')
      .select('id', { count: 'exact', head: true })
      .eq('status', 'queued')
    return new Response(JSON.stringify({ configured, queued: count ?? 0 }), {
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const cutoff = new Date(Date.now() - MAX_AGE_HOURS * 3600_000).toISOString()

  // Retire anything past its usefulness first, so stale rows never occupy a batch.
  let stale = 0
  if (!opts.dry_run) {
    const { data: expired } = await supabase
      .from('notification_deliveries')
      .update({ status: 'skipped', last_error: `expired unsent (older than ${MAX_AGE_HOURS}h)` })
      .eq('status', 'queued')
      .lt('created_at', cutoff)
      .select('id')
    stale = expired?.length ?? 0
  }

  const limit = Math.min(Math.max(Number(opts.limit) || BATCH, 1), 200)
  const { data: queue, error } = await supabase
    .from('notification_deliveries')
    .select('id, channel, address, title, body, attempts')
    .eq('status', 'queued')
    .gte('created_at', cutoff)
    .order('created_at', { ascending: true })
    .limit(limit)

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  if (opts.dry_run) {
    return new Response(
      JSON.stringify({
        dry_run: true,
        configured,
        would_send: (queue ?? []).map((d) => ({
          channel: d.channel,
          // Enough to recognise the recipient, not enough to be a phone list.
          to: String(d.address).slice(0, 7) + '…',
          text: composeSms(d as Delivery),
        })),
      }),
      { headers: { 'Content-Type': 'application/json' } },
    )
  }

  let sent = 0
  let failed = 0
  let skipped = 0
  let blocked: string | null = null

  for (const d of (queue ?? []) as Delivery[]) {
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
      const message = String(err instanceof Error ? err.message : err).slice(0, 500)

      if (err instanceof BlockedError) {
        // Nothing wrong with this row — leave it queued, untouched, and stop. The
        // next run picks up where we left off once the block is cleared.
        blocked = message
        await supabase
          .from('notification_deliveries')
          .update({ last_error: message })
          .eq('id', d.id)
        break
      }

      const attempts = d.attempts + 1
      const permanent = err instanceof PermanentError
      await supabase
        .from('notification_deliveries')
        .update({
          status: permanent || attempts >= MAX_ATTEMPTS ? 'failed' : 'queued',
          attempts,
          last_error: message,
        })
        .eq('id', d.id)
      failed++
    }
  }

  // Leave a trace on the audit page — this whole pipeline sat broken for weeks
  // precisely because nothing it did was visible to an admin.
  if (sent || failed || skipped || stale || blocked) {
    await supabase.from('audit_log').insert({
      actor_id: null,
      action: 'dispatch_notifications',
      target_type: 'system',
      details: { sent, failed, skipped, stale, ...(blocked ? { blocked } : {}) },
    })
  }

  return new Response(JSON.stringify({ sent, failed, skipped, stale, blocked }), {
    status: blocked ? 503 : 200,
    headers: { 'Content-Type': 'application/json' },
  })
})
