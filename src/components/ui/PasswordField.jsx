// Password input with a reveal toggle.
//
// Every password in this system arrives on paper: an admin creates the account,
// admin-create-member returns a generated temporary password, and it is read out
// or handed over. Typing that on a phone with every character masked, then being
// told only "Sign in failed. Check your email and password.", gives no way to
// tell a typo from a wrong password — so people retype it, fail again, and ask
// for a reset they did not need.
//
// The toggle is a 44px target inside the field's right padding, and it is a
// button rather than a checkbox so it never submits the form it sits in.
import { useId, useState } from 'react'
import { useLanguage } from '../../hooks/useLanguage'

export default function PasswordField({
  id,
  label,
  value,
  onChange,
  placeholder,
  autoComplete = 'current-password',
  required = true,
  // Rendered to the right of the label — the login screen's "Forgot?" link.
  action = null,
  // Set for a PIN: inputMode="numeric" brings up the number pad instead of the
  // full keyboard, which matters more here than anywhere else in the app — a PIN
  // is the whole credential for a member signing in on a phone.
  inputMode,
  maxLength,
}) {
  const { t } = useLanguage()
  const [shown, setShown] = useState(false)
  const generatedId = useId()
  const fieldId = id || generatedId

  return (
    <div>
      <div className="mb-1.5 flex items-baseline justify-between gap-3">
        <label htmlFor={fieldId} className="block text-sm font-medium text-slate-700">
          {label}
        </label>
        {action}
      </div>
      <div className="relative">
        <input
          id={fieldId}
          type={shown ? 'text' : 'password'}
          autoComplete={autoComplete}
          required={required}
          value={value}
          onChange={onChange}
          inputMode={inputMode}
          maxLength={maxLength}
          // Padding for the toggle, so a long password never runs under it.
          className="input-field pr-12"
          placeholder={placeholder}
        />
        <button
          type="button"
          onClick={() => setShown((v) => !v)}
          aria-label={shown ? t('Hide password') : t('Show password')}
          aria-pressed={shown}
          aria-controls={fieldId}
          className="absolute inset-y-0 right-0 inline-flex w-11 items-center justify-center rounded-r-xl text-slate-400 transition-colors hover:text-slate-700 active:text-slate-900"
        >
          <svg
            viewBox="0 0 24 24"
            width="18"
            height="18"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.8"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden
          >
            <path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z" />
            <circle cx="12" cy="12" r="3" />
            {shown && <path d="M4 20 20 4" />}
          </svg>
        </button>
      </div>
    </div>
  )
}
