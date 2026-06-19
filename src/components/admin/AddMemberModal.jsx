// Add member (v2). Admin enters name + phone + email (a name-based @umojagroup.app
// address is suggested, matching the seed convention) and the Edge Function creates
// the account, returning a temp password to share. Member changes it on first login.
import { useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { createMember } from '../../lib/admin'
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

function Form({ onCreated, onClose }) {
  const { t } = useLanguage()
  const [fullName, setFullName] = useState('')
  const [email, setEmail] = useState('')
  const [emailEdited, setEmailEdited] = useState(false)
  const [phone, setPhone] = useState('+255')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [created, setCreated] = useState(null) // { email, password }

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
      setCreated(result)
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
          {t('Member created. Share these temp credentials — they change the password on first login.')}
        </p>
        <div className="rounded-xl bg-slate-50 ring-1 ring-inset ring-slate-100 p-3 text-sm space-y-2">
          <div className="flex justify-between gap-3">
            <span className="text-slate-500">{t('Email')}</span>
            <span className="font-mono text-slate-900 break-all">{created.email}</span>
          </div>
          <div className="flex justify-between gap-3">
            <span className="text-slate-500">{t('Temp password')}</span>
            <span className="font-mono text-slate-900">{created.password}</span>
          </div>
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
        <label className="block text-sm font-medium text-slate-700 mb-1">{t('Email (login)')}</label>
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
          {t('A real email enables self-service password reset; otherwise you reset it for them.')}
        </p>
      </div>
      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">{t('Phone number')}</label>
        <input
          className="input-field"
          value={phone}
          onChange={(e) => setPhone(e.target.value)}
          placeholder="+255…"
        />
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
