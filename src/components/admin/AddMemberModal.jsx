// Add member (v2). Admin enters name + phone + email (a name-based @umojagroup.app
// address is suggested, matching the seed convention) and the Edge Function creates
// the account, returning a temp password to share. Member changes it on first login.
import { useState } from 'react'
import Modal from '../ui/Modal'
import { supabase } from '../../supabaseClient'
import { createMember } from '../../lib/admin'

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

const inputClass =
  'w-full rounded-lg border border-gray-300 px-3 py-2 text-gray-900 outline-none focus:border-emerald-500 focus:ring-2 focus:ring-emerald-200'

function Form({ onCreated, onClose }) {
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
      return setError('Name, email, and phone are all required.')
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
      setError(err?.message || 'Could not create the member.')
    } finally {
      setBusy(false)
    }
  }

  if (created) {
    return (
      <div className="space-y-4">
        <p className="text-sm text-gray-600">
          Member created. Share these temp credentials — they change the password on first login.
        </p>
        <div className="rounded-lg bg-gray-50 p-3 text-sm space-y-1">
          <div className="flex justify-between gap-3">
            <span className="text-gray-500">Email</span>
            <span className="font-mono text-gray-900 break-all">{created.email}</span>
          </div>
          <div className="flex justify-between gap-3">
            <span className="text-gray-500">Temp password</span>
            <span className="font-mono text-gray-900">{created.password}</span>
          </div>
        </div>
        <button
          onClick={onClose}
          className="w-full rounded-lg bg-emerald-600 text-white font-medium py-2.5 hover:bg-emerald-700"
        >
          Done
        </button>
      </div>
    )
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div>
        <label className="block text-sm font-medium text-gray-700 mb-1">Full name</label>
        <input className={inputClass} value={fullName} onChange={(e) => onNameChange(e.target.value)} placeholder="e.g. Jane Mushi" />
      </div>
      <div>
        <label className="block text-sm font-medium text-gray-700 mb-1">Email (login)</label>
        <input
          className={inputClass}
          type="email"
          value={email}
          onChange={(e) => {
            setEmail(e.target.value)
            setEmailEdited(true)
          }}
          placeholder="jane.mushi@umojagroup.app"
        />
        <p className="mt-1 text-xs text-gray-400">A real email enables self-service password reset; otherwise you reset it for them.</p>
      </div>
      <div>
        <label className="block text-sm font-medium text-gray-700 mb-1">Phone number</label>
        <input className={inputClass} value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="+255…" />
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <button
        type="submit"
        disabled={busy}
        className="w-full rounded-lg bg-emerald-600 text-white font-medium py-2.5 hover:bg-emerald-700 disabled:opacity-50"
      >
        {busy ? 'Creating…' : 'Create member'}
      </button>
    </form>
  )
}

export default function AddMemberModal({ open, onClose, onCreated }) {
  return (
    <Modal open={open} onClose={onClose} title="Add a member">
      {open && <Form onCreated={onCreated} onClose={onClose} />}
    </Modal>
  )
}
