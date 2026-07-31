// Overflow menu for row-level actions.
//
// The member grid used to print every action as its own coloured text link —
// four per row, in four different colours. On a seven-member group that put 28
// coloured words on screen, all of them shouting louder than the numbers they
// sat next to, and rows with fewer actions left a ragged right edge. One trigger
// per row fixes both: the column is always the same width, and the colour budget
// goes back to status.
//
// Dependency-free on purpose — the app ships no popover library and this is its
// only menu. Closes on outside pointer-down, on Escape (returning focus to the
// trigger), and after an item runs; arrow keys walk the items.
import { useCallback, useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'

// Matches min-h-11 below; used only to guess whether the menu fits underneath.
const ITEM_HEIGHT = 44

const ITEM_BASE =
  'flex min-h-11 w-full items-center rounded-lg px-3 text-left text-[13px] font-medium transition-colors duration-100'

const TONES = {
  default: 'text-slate-700 hover:bg-slate-50 active:bg-slate-100',
  danger: 'text-red-600 hover:bg-red-50 active:bg-red-100',
}

export default function ActionMenu({ actions, label }) {
  const [open, setOpen] = useState(false)
  const [dropUp, setDropUp] = useState(false)
  const rootRef = useRef(null)
  const triggerRef = useRef(null)
  const menuRef = useRef(null)

  const close = useCallback((refocus = false) => {
    setOpen(false)
    if (refocus) triggerRef.current?.focus()
  }, [])

  useEffect(() => {
    if (!open) return
    const onPointerDown = (e) => {
      if (!rootRef.current?.contains(e.target)) setOpen(false)
    }
    const onKeyDown = (e) => {
      if (e.key === 'Escape') close(true)
    }
    document.addEventListener('pointerdown', onPointerDown)
    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('pointerdown', onPointerDown)
      document.removeEventListener('keydown', onKeyDown)
    }
  }, [open, close])

  // Land on the first item so the menu is usable from the keyboard alone.
  useEffect(() => {
    if (open) menuRef.current?.querySelector('[role="menuitem"]')?.focus()
  }, [open])

  function toggle() {
    if (open) return close()
    // A menu opened on the last row of a long grid would otherwise run off the
    // bottom of the viewport; flip it above the trigger when it doesn't fit.
    const rect = triggerRef.current?.getBoundingClientRect()
    const needed = actions.length * ITEM_HEIGHT + 16
    setDropUp(
      Boolean(rect) && rect.bottom + needed > window.innerHeight && rect.top > needed,
    )
    setOpen(true)
  }

  function onMenuKeyDown(e) {
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return
    e.preventDefault()
    const items = Array.from(menuRef.current?.querySelectorAll('[role="menuitem"]') || [])
    if (!items.length) return
    const from = items.indexOf(document.activeElement)
    const step = e.key === 'ArrowDown' ? 1 : -1
    items[(from + step + items.length) % items.length]?.focus()
  }

  if (!actions.length) return null

  return (
    <div ref={rootRef} className="relative inline-block">
      <button
        ref={triggerRef}
        type="button"
        onClick={toggle}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={label}
        className={`inline-flex size-11 items-center justify-center rounded-xl transition-colors duration-100 ${
          open ? 'bg-slate-100 text-slate-600' : 'text-slate-400 hover:bg-slate-100 hover:text-slate-600'
        }`}
        style={{ touchAction: 'manipulation' }}
      >
        <svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" className="size-4">
          <circle cx="10" cy="4" r="1.6" />
          <circle cx="10" cy="10" r="1.6" />
          <circle cx="10" cy="16" r="1.6" />
        </svg>
      </button>

      {open && (
        <div
          ref={menuRef}
          role="menu"
          aria-label={label}
          onKeyDown={onMenuKeyDown}
          data-sheet-enter
          className={`absolute right-0 z-30 w-52 rounded-xl border border-slate-200/80 bg-white p-1 shadow-pop ${
            dropUp ? 'bottom-full mb-1' : 'top-full mt-1'
          }`}
        >
          {actions.map((a, i) => {
            const tone = TONES[a.tone] || TONES.default
            // Destructive actions sit behind a rule so a mis-tap needs intent.
            const divided = a.tone === 'danger' && actions[i - 1]?.tone !== 'danger'
            return (
              <div key={a.key} className={divided ? 'mt-1 border-t border-slate-100 pt-1' : ''}>
                {a.to ? (
                  <Link to={a.to} role="menuitem" onClick={() => setOpen(false)} className={`${ITEM_BASE} ${tone}`}>
                    {a.label}
                  </Link>
                ) : (
                  <button
                    type="button"
                    role="menuitem"
                    onClick={() => {
                      setOpen(false)
                      a.onClick?.()
                    }}
                    className={`${ITEM_BASE} ${tone}`}
                  >
                    {a.label}
                  </button>
                )}
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
