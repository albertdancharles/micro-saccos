import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
// The other half of the fix: the page must declare the language it is actually
// rendering. While index.html's hardcoded lang="sw" outlived the EN toggle, an
// English-reading browser was offered a translation of a page it had been told
// was Swahili — and accepting that offer is what turned Amani into "Peaceful".
describe('document language', () => {
  it('follows the language the member chose', async () => {
    const { LanguageProvider, useLanguage } = await import('./useLanguage')

    function Toggle() {
      const { lang, toggle } = useLanguage()
      return <button onClick={toggle}>{lang}</button>
    }

    render(
      <LanguageProvider>
        <Toggle />
      </LanguageProvider>,
    )
    expect(document.documentElement.lang).toBe('sw')

    await userEvent.click(screen.getByRole('button'))
    expect(document.documentElement.lang).toBe('en')
  })
})
