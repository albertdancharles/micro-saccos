// A person's name, fenced off from machine translation.
//
// The app declares its language on <html> (useLanguage keeps it honest), which
// is enough for a browser to stop offering to translate a page the member is
// already reading in their own language. It is not enough when the member asks
// for a translation anyway: Chrome then rewrites every text node it can reach,
// and a name that is also an ordinary Swahili word does not survive the trip —
// Amani came back as "Peace", and on a later pass "Peaceful". A member who
// cannot find their own name in the ledger stops trusting the ledger.
//
// translate="no" is the standard opt-out and is honoured by Chrome, Edge, Safari
// and Firefox; the notranslate class covers older Google Translate widgets that
// only look for that. Everything around the name still translates.
//
// Use this for anything that names a human being. Do not use it for labels,
// statuses or free text — those are exactly what the reader asked to translate.
export default function Name({ children, as: Tag = 'span', className = '', ...rest }) {
  return (
    <Tag translate="no" className={`notranslate ${className}`.trim()} {...rest}>
      {children}
    </Tag>
  )
}
