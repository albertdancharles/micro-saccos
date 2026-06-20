// Loads a fresh signed URL for a private payment/disbursement proof on demand.
// Signed URLs expire (see lib/storage), so we never cache — the admin clicks
// "View screenshot" and we fetch a short-lived link. Shared by the payment and
// loan approval queue items, which had identical copies of this logic.
import { useState } from 'react'
import { supabase } from '../supabaseClient'
import { getSignedUrl } from '../lib/storage'

export function useSignedProof() {
  const [proofUrl, setProofUrl] = useState(null)
  const [loadingProof, setLoadingProof] = useState(false)
  const [error, setError] = useState('')

  async function viewProof(path) {
    setError('')
    setLoadingProof(true)
    try {
      setProofUrl(await getSignedUrl(supabase, path))
    } catch (err) {
      setError(err?.message || 'Could not load the screenshot.')
    } finally {
      setLoadingProof(false)
    }
  }

  return { proofUrl, loadingProof, viewProof, error, setError }
}
