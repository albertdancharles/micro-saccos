// Storage helpers (build plan §7, §8e). Proofs live in the private `payment-proofs`
// bucket. Member uploads MUST put member_id as the 2nd path segment or the storage
// INSERT policy rejects them.
const BUCKET = 'payment-proofs'
export const MAX_PROOF_BYTES = 5 * 1024 * 1024 // 5 MB (server enforces too)
export const ALLOWED_PROOF_TYPES = ['image/jpeg', 'image/png', 'image/webp']

const EXT_BY_TYPE = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' }

// Client-side mirror of the bucket's mime/size limits, for an immediate error.
export function validateProofFile(file) {
  if (!file) return 'Choose a screenshot to upload.'
  if (!ALLOWED_PROOF_TYPES.includes(file.type)) return 'Upload a JPG, PNG, or WebP image.'
  if (file.size > MAX_PROOF_BYTES) return 'Image must be 5 MB or smaller.'
  return null
}

// Builds a storage path with member_id as the 2nd segment (storage RLS requirement).
// A random file id avoids the chicken-and-egg of needing the submission id first.
export function buildProofPath({ submissionType, memberId, period, loanId, installmentNumber, file }) {
  const ext = EXT_BY_TYPE[file.type] || 'jpg'
  const id = crypto.randomUUID()
  switch (submissionType) {
    case 'savings_deposit':
      return `savings/${memberId}/${id}.${ext}`
    case 'monthly_fee':
      return `fees/${memberId}/${period}/${id}.${ext}`
    case 'loan_installment':
      return `loan-repayments/${memberId}/${loanId}/${installmentNumber}/${id}.${ext}`
    default:
      throw new Error(`Unknown submission type: ${submissionType}`)
  }
}

// Admin disbursement proof path (build plan §7). The admin-upload policy only checks
// is_admin(), so any path works; we keep it under loan-disbursements/{loan_id}/.
export function buildDisbursementPath(loanId, file) {
  const ext = EXT_BY_TYPE[file.type] || 'jpg'
  return `loan-disbursements/${loanId}/${crypto.randomUUID()}.${ext}`
}

export async function uploadPaymentProof(supabase, file, path) {
  const { data, error } = await supabase.storage
    .from(BUCKET)
    .upload(path, file, { upsert: false, contentType: file.type })
  if (error) throw error
  return data.path
}

// Signed URLs expire — fetch fresh each time, never cache (build plan §7). Default is
// a short 10 min: proofs are viewed immediately on click, so a brief window is enough
// and narrows exposure if a link leaks. Callers may pass a longer TTL if ever needed.
export async function getSignedUrl(supabase, path, expiresInSeconds = 600) {
  const { data, error } = await supabase.storage.from(BUCKET).createSignedUrl(path, expiresInSeconds)
  if (error) throw error
  return data.signedUrl
}
