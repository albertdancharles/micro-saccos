// Add member (v3). Admin enters name + phone + email (a name-based @umojagroup.app
// address is suggested, matching the seed convention), the Edge Function creates the
// account, and a sign-in PIN is minted for it.
//
// What changed in v3 and why the handover screen is shaped the way it is: since 042 a
// member signs in with their first name, their phone number and a PIN. So those three
// things are what the admin reads out, and they are shown together as one set of
// instructions rather than as a credential dump. The email and temp password are
// still created and still work, but they are folded away — a member has no inbox at
// that address and in practice never types it, and leading with it is what made
// every forgotten login an admin reset.
//
// Two calls, not one: the account is created by admin-create-member and the PIN is
// minted by member-pin-auth. That is deliberate (one copy of the PBKDF2 hashing, see
// member-pin-auth's header) and it means the second call can fail on its own. If it
// does, the member exists without a PIN, which is recoverable from the Sign-in PINs
// panel — so that is exactly what the error says to do, rather than implying the
// whole thing failed.
import { useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { createMember } from '../../lib/admin'
import { resetMemberPin } from '../../lib/phoneAuth'
import { useLanguage } from '../../hooks/useLanguage'

// firstname.lastname@umojagroup.app from a full name.
function suggestEmail(name) {
  const parts = name
    .trim()
    .toLowerCase()
    .replace(/[^a-z\s]/g, '')
    .split(/\s+/)
    .filter(Boolean)
  if (!parts.length) return ''
  const local = parts.length === 1 ? parts[0] : `${parts[0]}.${parts[parts.length - 1]}`
  return `${local}@umojagroup.app`
}

function firstWord(name) {
  return String(name || '').trim().split(/\s+/)[0] || ''
}

function HandoverRow({ label, value, mono = true }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <span className="shrink-0 text-xs text-slate-500">{label}</span>
      <span className={`text-right text-slate-900 break-all ${mono ? 'font-mono' : ''}`}>
        {value}
      </span>
    </div>
  )
}

function Form({ onCreated, onClose }) {
  const { t } = useLanguage()
  const [fullName, setFullName] = useState('')
  const [email, setEmail] = useState('')
  const [emailEdited, setEmailEdited] = useState(false)
  const [phone, setPhone] = useState('+255')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  // { firstName, phone, pin, pinError, email, password }
  const [created, setCreated] = useState(null)
  const [showFallback, setShowFallback] = useState(false)

  function onNameChange(value) {
    setFullName(value)
    if (!emailEdited) setEmail(suggestEmail(value))
  }

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')
    if (!fullName.trim() || !email.trim() || !phone.trim()) {
      return setError(t('Name, email, and phone are all required.'))
    }
    setBusy(true)
    try {
      const result = await createMember(supabase, {
        full_name: fullName.trim(),
        email: email.trim(),
        phone_number: phone.trim(),
      })

      // The account exists from here on. A failure minting the PIN must not read as
      // "nothing happened" — it is one recoverable step short of done.
      let pin = null
      let pinError = ''
      try {
        const minted = await resetMemberPin(result.id)
        pin = minted?.pin ?? null
      } catch (err) {
        pinError = err?.message || t('Could not create the PIN.')
      }

      setCreated({
        firstName: firstWord(fullName),
        phone: phone.trim(),
        pin,
        pinError,
        email: result.email,
        password: result.password,
      })
      onCreated?.()
    } catch (err) {
      setError(err?.message || t('Could not create the member.'))
    } finally {
      setBusy(false)
    }
  }

  if (created) {
    return (
      <div className="space-y-4">
        <p className="text-sm text-slate-600">
          {t('Member created. Read these three things out — they are how they sign in.')}
        </p>

        <div className="rounded-xl bg-emerald-50 p-3 ring-1 ring-inset ring-emerald-100 space-y-2 text-sm">
          <HandoverRow label={t('First name')} value={created.firstName} mono={false} />
          <HandoverRow label={t('Phone number')} value={created.phone} />
          {created.pin ? (
            <div className="flex items-baseline justify-between gap-3">
              <span className="shrink-0 text-xs text-slate-500">{t('PIN')}</span>
              <span className="font-mono text-2xl tracking-[0.3em] text-emerald-900">
                {created.pin}
              </span>
            </div>
          ) : (
            <p role="alert" className="text-xs text-red-700">
              {t('The account was created but the PIN was not: {reason} Set one from the Sign-in PINs panel.').replace(
                '{reason}',
                created.pinError,
              )}
            </p>
          )}
        </div>

        {created.pin && (
          <p className="text-xs text-slate-500">
            {t('They will be asked to choose their own PIN the first time they sign in, so this one stops working then.')}
          </p>
        )}

        {/* Folded away, not removed. It is the admin's way back in if phone login is
            ever misbehaving, and it is the only login with a working reset email. */}
        <div>
          <button
            type="button"
            onClick={() => setShowFallback((v) => !v)}
            className="text-xs font-medium text-slate-500 hover:text-slate-700"
          >
            {showFallback ? t('Hide email login') : t('Show email login (backup)')}
          </button>
          {showFallback && (
            <div className="mt-2 rounded-xl bg-slate-50 p-3 ring-1 ring-inset ring-slate-100 space-y-2 text-sm">
              <HandoverRow label={t('Email')} value={created.email} />
              <HandoverRow label={t('Temp password')} value={created.password} />
            </div>
          )}
        </div>

        <button onClick={onClose} className="btn-primary w-full">
          {t('Done')}
        </button>
      </div>
    )
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">{t('Full name')}</label>
        <input
          className="input-field"
          value={fullName}
          onChange={(e) => onNameChange(e.target.value)}
          placeholder="e.g. Jane Mushi"
        />
      </div>
      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">{t('Phone number')}</label>
        <input
          className="input-field"
          type="tel"
          inputMode="tel"
          value={phone}
          onChange={(e) => setPhone(e.target.value)}
          placeholder="+255…"
        />
        {/* Promoted above the email field: this is half the member's login now, and
            it has to be the number they actually answer. */}
        <p className="mt-1 text-xs text-slate-400">
          {t('Half of their login. Make sure it is the number they use.')}
        </p>
      </div>
      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">{t('Email (backup login)')}</label>
        <input
          className="input-field"
          type="email"
          value={email}
          onChange={(e) => {
            setEmail(e.target.value)
            setEmailEdited(true)
          }}
          placeholder="jane.mushi@umojagroup.app"
        />
        <p className="mt-1 text-xs text-slate-400">
          {t('Members sign in by phone and PIN. A real email here also enables self-service password reset.')}
        </p>
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <button type="submit" disabled={busy} className="btn-primary w-full">
        {busy ? t('Creating…') : t('Create member')}
      </button>
    </form>
  )
}

export default function AddMemberModal({ open, onClose, onCreated }) {
  const { t } = useLanguage()
  return (
    <Modal open={open} onClose={onClose} title={t('Add a member')}>
      {open && <Form onCreated={onCreated} onClose={onClose} />}
    </Modal>
  )
}
