import Name from './Name'

// Fills a translated template that mentions a person.
//
// The plain `t('Delete {name}').replace('{name}', row.name)` produces one text
// node, so there is no way to protect the person inside it: translate="no" on
// the parent would freeze the sentence too, and leaving it open lets the name
// through the translator with everything else. This splits the filled template
// into parts and hands only the person to <Name>, so "Delete Amani" translates
// to "Futa Amani" and never to "Delete Peaceful".
//
// Returns an array of nodes, so it goes straight into JSX. It is not a string:
// for an aria-label or a title attribute, keep using .replace().
const PLACEHOLDER = /\{(\w+)\}/g

export function fillNames(template, values, people = ['name', 'names']) {
  const parts = []
  let last = 0
  let match
  PLACEHOLDER.lastIndex = 0
  while ((match = PLACEHOLDER.exec(template)) !== null) {
    if (match.index > last) parts.push(template.slice(last, match.index))
    const key = match[1]
    const value = values[key]
    if (value === undefined) {
      // An unfilled placeholder stays visible, exactly as .replace() would leave
      // it — a missing value should look like a bug, not like missing words.
      parts.push(match[0])
    } else if (people.includes(key)) {
      parts.push(
        <Name key={`${key}-${match.index}`}>{value}</Name>,
      )
    } else {
      parts.push(String(value))
    }
    last = match.index + match[0].length
  }
  if (last < template.length) parts.push(template.slice(last))
  return parts
}
