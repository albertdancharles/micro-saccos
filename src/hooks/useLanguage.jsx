import { createContext, useContext, useState } from 'react'
import { createTranslator } from '../lib/translations'

const LanguageContext = createContext(null)

export function LanguageProvider({ children }) {
  const [lang, setLang] = useState(() => localStorage.getItem('lang') || 'en')

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

export function useLanguage() {
  return useContext(LanguageContext)
}
