// Choose a PIN. Used in two places, which is why it is a component and not part of
// either screen:
//
//   /set-pin — a member signing in on a PIN the admin issued, held there until they
//              pick their own. No current PIN asked for: the session already proves
//              they were given the old one, and retyping a code that was read aloud
//              protects nothing.
//   Profile  — changing a PIN they already chose. Asks for the current one, so a
//              phone left unlocked on a table is not enough to take over the login.
//
// The confirm field is not ceremony. A mistyped PIN that is only discovered at the
// next sign-in costs the member an admin reset, and the admin a phone call.
import { useState } from 'react'
import { useLanguage } from '../../hooks/useLanguage'
import { setOwnPin, pinProblem } from '../../lib/phoneAuth'
import PasswordField from './PasswordField'

export default function PinForm({ requireCurrent = false, submitLabel, onSaved }) {
  const { t } = useLanguage()
  const [currentPin, setCurrentPin] = useState('')
  const [pin, setPin] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    setNotice('')
    if (busy) return

    if (requireCurrent && !currentPin) return setError(t('Enter your current PIN.'))
    const problem = pinProblem(pin)
    if (problem) return setError(t(problem))
    if (pin !== confirm) return setError(t('The two PINs do not match.'))

    setBusy(true)
    try {
      await setOwnPin({ pin, currentPin: requireCurrent ? currentPin : undefined })
      setCurrentPin('')
      setPin('')
      setConfirm('')
      setNotice(t('PIN saved.'))
      onSaved?.()
    } catch (err) {
      setError(t(err?.message) || t('Could not save your PIN.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      {requireCurrent && (
        <PasswordField
          id="current-pin"
          label={t('Current PIN')}
          value={currentPin}
          onChange={(e) => setCurrentPin(e.target.value)}
          placeholder="••••"
          autoComplete="current-password"
          inputMode="numeric"
          maxLength={6}
        />
      )}

      <PasswordField
        id="new-pin"
        label={t('New PIN')}
        value={pin}
        onChange={(e) => setPin(e.target.value)}
        placeholder="••••"
        autoComplete="new-password"
        inputMode="numeric"
        maxLength={6}
      />

      <PasswordField
        id="confirm-pin"
        label={t('Confirm new PIN')}
        value={confirm}
        onChange={(e) => setConfirm(e.target.value)}
        placeholder="••••"
        autoComplete="new-password"
        inputMode="numeric"
        maxLength={6}
      />

      <p className="text-xs text-slate-400">
        {t('4 to 6 digits. Avoid 1234 or 0000, and do not use your year of birth.')}
      </p>

      {error && (
        <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 ring-1 ring-inset ring-red-100">
          {error}
        </p>
      )}
      {notice && (
        <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-700 ring-1 ring-inset ring-emerald-100">
          {notice}
        </p>
      )}

      <button type="submit" disabled={busy} className="btn-primary w-full">
        {busy ? t('Saving…') : submitLabel || t('Save PIN')}
      </button>
    </form>
  )
}
