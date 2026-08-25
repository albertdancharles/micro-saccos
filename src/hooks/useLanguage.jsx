import { createContext, useContext, useState } from 'react'
import { createTranslator } from '../lib/translations'
import { supabase } from '../supabaseClient'

const LanguageContext = createContext(null)

export function LanguageProvider({ children }) {
  const [lang, setLang] = useState(() => localStorage.getItem('lang') || 'sw')

  function toggle() {
    const next = lang === 'en' ? 'sw' : 'en'
    setLang(next)
    localStorage.setItem('lang', next)

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
