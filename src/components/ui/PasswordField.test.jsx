// The reveal toggle is the whole point of this component: every password in this
// system is handed over on paper and typed once, on a phone. If the toggle does
// not actually unmask the field, or does not say which state it is in, it is
// worse than not having one.
import { beforeEach, describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { LanguageProvider } from '../../hooks/useLanguage'
import PasswordField from './PasswordField'

beforeEach(() => localStorage.setItem('lang', 'en'))

function renderField(props = {}) {
  return render(
    <LanguageProvider>
      <PasswordField label="Password" value="hunter2" onChange={() => {}} {...props} />
    </LanguageProvider>,
  )
}

describe('PasswordField', () => {
  it('associates its label with the input', () => {
    renderField()
    expect(screen.getByLabelText('Password')).toHaveAttribute('type', 'password')
  })

  it('unmasks and re-masks the value', async () => {
    renderField()

    await userEvent.click(screen.getByRole('button', { name: 'Show password' }))
    expect(screen.getByLabelText('Password')).toHaveAttribute('type', 'text')

    await userEvent.click(screen.getByRole('button', { name: 'Hide password' }))
    expect(screen.getByLabelText('Password')).toHaveAttribute('type', 'password')
  })

  it('reports its state to assistive tech', async () => {
    renderField()
    const toggle = screen.getByRole('button', { name: 'Show password' })
    expect(toggle).toHaveAttribute('aria-pressed', 'false')

    await userEvent.click(toggle)
    expect(screen.getByRole('button', { name: 'Hide password' })).toHaveAttribute(
      'aria-pressed',
      'true',
    )
  })

  // It lives inside <form onSubmit={…}> on three screens. A bare <button> defaults
  // to type="submit", which would post the form on every reveal.
  it('does not submit the form it sits in', () => {
    renderField()
    expect(screen.getByRole('button', { name: 'Show password' })).toHaveAttribute('type', 'button')
  })

  // Two fields on one screen (new password + confirm) must not share an id, or
  // the label of the second points at the first.
  it('generates distinct ids when none is given', () => {
    render(
      <LanguageProvider>
        <PasswordField label="New password" value="" onChange={() => {}} />
        <PasswordField label="Confirm" value="" onChange={() => {}} />
      </LanguageProvider>,
    )
    const a = screen.getByLabelText('New password')
    const b = screen.getByLabelText('Confirm')
    expect(a.id).toBeTruthy()
    expect(a.id).not.toBe(b.id)
  })
})
