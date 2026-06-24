import { createContext, useContext, useState } from 'react'
import { createTranslator } from '../lib/translations'

const LanguageContext = createContext(null)

export function LanguageProvider({ children }) {
  const [lang, setLang] = useState(() => localStorage.getItem('lang') || 'sw')

  function toggle() {
    const next = lang === 'en' ? 'sw' : 'en'
    setLang(next)
    localStorage.setItem('lang', next)
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
