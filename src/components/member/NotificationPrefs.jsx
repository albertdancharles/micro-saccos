// How the group reaches this member (migration 026).
//
// SMS is on by default because it is the only channel that reaches a feature phone
// — but it costs the group money per message, so it is the member's to turn off.
// Push is free and off until they grant permission on this device.
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../supabaseClient'
import {
  getNotificationPrefs,
  updateNotificationPrefs,
  subscribeToPush,
  unsubscribeFromPush,
  pushSupported,
} from '../../lib/push'
import { useLanguage } from '../../hooks/useLanguage'

function Toggle({ id, label, hint, checked, disabled, onChange }) {
  return (
    <div className="flex items-start justify-between gap-3 py-3">
      <label htmlFor={id} className="min-w-0">
        <span className="block text-sm font-medium text-slate-900">{label}</span>
        {hint && <span className="block text-xs text-slate-500 mt-0.5">{hint}</span>}
      </label>
      <input
        id={id}
        type="checkbox"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
        className="mt-1 size-5 shrink-0 accent-emerald-600 disabled:opacity-40"
      />
    </div>
  )
}

export default function NotificationPrefs({ memberId }) {
  const { t } = useLanguage()
  const [prefs, setPrefs] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [unavailable, setUnavailable] = useState(false)

  const load = useCallback(async () => {
    if (!supabase || !memberId) return
    try {
      setPrefs(await getNotificationPrefs(supabase, memberId))
    } catch {
      // Migration 026 not applied — hide the card rather than break the page.
      setUnavailable(true)
    }
  }, [memberId])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  if (unavailable || !prefs) return null

  async function save(next) {
    setError('')
    setBusy(true)
    try {
      // Push has to be granted on THIS device before the flag means anything, so
      // the subscription happens first and the flag only follows if it succeeded.
      let pushEnabled = next.push_enabled
      if (next.push_enabled && !prefs.push_enabled) {
        pushEnabled = await subscribeToPush(supabase, memberId)
        if (!pushEnabled) setError(t('Your browser did not allow notifications on this device.'))
      } else if (!next.push_enabled && prefs.push_enabled) {
        await unsubscribeFromPush(supabase)
      }

      await updateNotificationPrefs(supabase, {
        smsOptIn: next.sms_opt_in,
        pushEnabled,
      })
      setPrefs({ ...next, push_enabled: pushEnabled })
    } catch (err) {
      setError(err?.message || t('Could not save your notification settings.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="space-y-1">
      <div className="divide-y divide-slate-100">
        <Toggle
          id="pref-sms"
          label={t('Text message reminders')}
          hint={
            prefs.phone_e164
              ? t('Sent to {phone}').replace('{phone}', prefs.phone_e164)
              : t('Add your phone number above so the group can text you.')
          }
          checked={!!prefs.sms_opt_in}
          disabled={busy || !prefs.phone_e164}
          onChange={(v) => save({ ...prefs, sms_opt_in: v })}
        />
        <Toggle
          id="pref-push"
          label={t('Notifications on this device')}
          hint={
            pushSupported()
              ? t('Free. Works best once you install the app to your home screen.')
              : t('This browser does not support notifications.')
          }
          checked={!!prefs.push_enabled}
          disabled={busy || !pushSupported()}
          onChange={(v) => save({ ...prefs, push_enabled: v })}
        />
      </div>
      {error && <p className="text-sm text-red-600">{error}</p>}
      <p className="text-xs text-slate-400 pt-1">
        {t('You are always reminded in the app. These are for reaching you outside it.')}
      </p>
    </div>
  )
}
