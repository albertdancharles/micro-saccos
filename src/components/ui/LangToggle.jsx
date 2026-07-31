import { useLanguage } from '../../hooks/useLanguage'

export default function LangToggle() {
  const { lang, toggle } = useLanguage()
  return (
    <button
      onClick={toggle}
      // 11px type in a 44px target: the label stays compact but the hit area
      // meets the touch minimum instead of being a ~20px sliver in the header.
      className="inline-flex h-11 items-center justify-center rounded-full px-2 text-[11px] font-semibold leading-none tracking-wide transition-colors hover:bg-slate-100 active:bg-slate-200/70"
      aria-label={lang === 'en' ? 'Switch to Swahili' : 'Badilisha kwa Kiingereza'}
    >
      <span className={lang === 'en' ? 'text-slate-900' : 'text-slate-400'}>EN</span>
      <span className="text-slate-300 mx-0.5">|</span>
      <span className={lang === 'sw' ? 'text-slate-900' : 'text-slate-400'}>SW</span>
    </button>
  )
}
