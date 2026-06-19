import { useLanguage } from '../../hooks/useLanguage'

export default function LangToggle() {
  const { lang, toggle } = useLanguage()
  return (
    <button
      onClick={toggle}
      className="text-[11px] font-semibold tracking-wide transition-colors leading-none"
      aria-label={lang === 'en' ? 'Switch to Swahili' : 'Badilisha kwa Kiingereza'}
    >
      <span className={lang === 'en' ? 'text-slate-900' : 'text-slate-400'}>EN</span>
      <span className="text-slate-300 mx-0.5">|</span>
      <span className={lang === 'sw' ? 'text-slate-900' : 'text-slate-400'}>SW</span>
    </button>
  )
}
