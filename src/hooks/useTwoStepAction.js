// Shared busy/error plumbing for the two-of-N admin queue cards (savings edit,
// pool edit, role change, member deletion). Each card supplies its own approve
// and cancel calls, the confirm prompt for cancel, and fallback error messages;
// the try/catch/finally shape is identical across all four, so it lives here.
import { useState } from 'react'

export function useTwoStepAction({ onApprove, onCancel, confirmCancel, approveError, cancelError }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  async function handleApprove() {
    setError('')
    setBusy(true)
    try {
      await onApprove()
    } catch (err) {
      setError(err?.message || approveError)
    } finally {
      setBusy(false)
    }
  }

  async function handleCancel() {
    setError('')
    if (confirmCancel && !window.confirm(confirmCancel)) return
    setBusy(true)
    try {
      await onCancel()
    } catch (err) {
      setError(err?.message || cancelError)
    } finally {
      setBusy(false)
    }
  }

  return { busy, error, handleApprove, handleCancel }
}
