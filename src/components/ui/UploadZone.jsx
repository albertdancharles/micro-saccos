// Screenshot upload (build plan §9). Tap-to-upload with thumbnail preview and an
// immediate client-side mime/size check mirroring the bucket limits (§7).
// UI/UX Pro Max: large 44pt+ touch target, helper text under the zone, clear
// pressed/hover state on the dashed area, error placed near the field (§8).
import { useEffect, useMemo, useRef, useState } from 'react'
import { validateProofFile } from '../../lib/storage'
import { useLanguage } from '../../hooks/useLanguage'

function UploadIcon() {
  return (
    <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" className="text-slate-400">
      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
      <polyline points="17 8 12 3 7 8" />
      <line x1="12" y1="3" x2="12" y2="15" />
    </svg>
  )
}

export default function UploadZone({ file, onSelect }) {
  const { t } = useLanguage()
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
        className="group w-full rounded-xl border-2 border-dashed border-slate-300 bg-slate-50/60 p-6 text-center transition-all duration-150 hover:border-emerald-400 hover:bg-emerald-50/40 active:scale-[0.99]"
      >
        {preview ? (
          <img
            src={preview}
            alt="Proof preview"
            className="mx-auto max-h-44 rounded-lg object-contain"
          />
        ) : (
          <span className="inline-flex flex-col items-center gap-2 text-sm text-slate-600">
            <span className="grid place-items-center w-10 h-10 rounded-full bg-white ring-1 ring-slate-200 group-hover:ring-emerald-200 transition-colors">
              <UploadIcon />
            </span>
            <span className="font-medium">{t('Tap to upload screenshot')}</span>
            <span className="text-xs text-slate-400">{t('JPG, PNG, or WebP — up to 5 MB')}</span>
          </span>
        )}
      </button>
      {file && (
        <p className="mt-2 text-xs text-slate-500 truncate">
          <span className="text-slate-400">{t('Selected:')}</span> {file.name}
        </p>
      )}
      {error && <p className="mt-2 text-sm text-red-600">{error}</p>}
    </div>
  )
}
