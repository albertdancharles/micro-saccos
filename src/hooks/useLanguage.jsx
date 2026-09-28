import { createContext, useContext, useState } from 'react'
import { createTranslator } from '../lib/translations'
import { supabase } from '../supabaseClient'

const LanguageContext = createContext(null)

// localStorage is not always there to be read. Accessing it THROWS — it does not
// return null — when site data is blocked, in some in-app browsers, and in Safari
// private mode; unguarded, that threw during the provider's initial state and took
// the whole app down to a white screen before anything rendered. A remembered
// language is a convenience, so it fails quietly and falls back to Swahili.
const readLang = () => {
  try {
    return localStorage.getItem('lang') || 'sw'
  } catch {
    return 'sw'
  }
}

const writeLang = (value) => {
  try {
    localStorage.setItem('lang', value)
  } catch {
    // Not remembering the choice is survivable; refusing to switch is not.
  }
}

export function LanguageProvider({ children }) {
  const [lang, setLang] = useState(readLang)

  function toggle() {
    const next = lang === 'en' ? 'sw' : 'en'
    setLang(next)
    writeLang(next)

    // Reminders are composed server-side in `profiles.preferred_language`
    // (migration 033), so a choice made only in localStorage would leave a member
    // reading the app in English while their texts arrive in Swahili. Best effort:
    // this toggle also lives on the login screen, where there is no session to
    // save against, and failing to persist a preference must never block it.
    supabase
      ?.rpc('update_notification_prefs', {
        p_sms_opt_in: null,
        p_push_enabled: null,
        p_language: next,
      })
      .then(() => {})
      .catch(() => {})
  }

  const t = createTranslator(lang)
  return (
    <LanguageContext.Provider value={{ lang, toggle, t }}>
      {children}
    </LanguageContext.Provider>
  )
}

// Provider + hook live together (same pattern as useAuth). The hook export trips
// react-refresh's components-only rule, which is harmless here — Fast Refresh still
// updates the provider correctly.
// eslint-disable-next-line react-refresh/only-export-components
export function useLanguage() {
  return useContext(LanguageContext)
}
