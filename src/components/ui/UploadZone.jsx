// Screenshot upload (build plan §9). Tap-to-upload with thumbnail preview and an
// immediate client-side mime/size check mirroring the bucket limits (§7).
import { useEffect, useMemo, useRef, useState } from 'react'
import { validateProofFile } from '../../lib/storage'

export default function UploadZone({ file, onSelect }) {
  const inputRef = useRef(null)
  const [error, setError] = useState('')

  // Derive the thumbnail URL from the file (no state), and revoke it on change/
  // unmount via a cleanup-only effect to avoid leaks.
  const preview = useMemo(() => (file ? URL.createObjectURL(file) : null), [file])
  useEffect(() => () => preview && URL.revokeObjectURL(preview), [preview])

  function handleChange(e) {
    const picked = e.target.files?.[0]
    if (!picked) return
    const msg = validateProofFile(picked)
    setError(msg || '')
    onSelect(msg ? null : picked)
  }

  return (
    <div>
      <input
        ref={inputRef}
        type="file"
        accept="image/jpeg,image/png,image/webp"
        className="hidden"
        onChange={handleChange}
      />
      <button
        type="button"
        onClick={() => inputRef.current?.click()}
        className="w-full rounded-lg border-2 border-dashed border-gray-300 p-4 text-center hover:border-emerald-400 transition-colors"
      >
        {preview ? (
          <img src={preview} alt="Proof preview" className="mx-auto max-h-40 rounded-md object-contain" />
        ) : (
          <span className="text-sm text-gray-500">Tap to upload payment screenshot</span>
        )}
      </button>
      {file && (
        <p className="mt-1 text-xs text-gray-400 truncate">{file.name}</p>
      )}
      {error && <p className="mt-1 text-sm text-red-600">{error}</p>}
    </div>
  )
}
