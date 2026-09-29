// A member's name is the one string on the screen that must survive a machine
// translation intact — Amani is a person, not the Swahili word for peace. The
// browser's page translator honours translate="no", so these guard the two
// things that would silently remove that protection: the attribute going
// missing, and the name being folded back into the surrounding text node.
import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import Name from './Name'
import { fillNames } from './fillNames'

describe('Name', () => {
  it('fences the name off from a page translator', () => {
    render(<Name>Amani Ngoko</Name>)
    const el = screen.getByText('Amani Ngoko')
    expect(el).toHaveAttribute('translate', 'no')
    expect(el).toHaveClass('notranslate')
  })

  it('keeps the caller’s own classes', () => {
    render(<Name className="truncate">Amani Ngoko</Name>)
    expect(screen.getByText('Amani Ngoko')).toHaveClass('truncate', 'notranslate')
  })
})

describe('fillNames', () => {
  it('leaves the person in their own element and the sentence outside it', () => {
    const { container } = render(
      <p>{fillNames('Delete {name}', { name: 'Amani Ngoko' })}</p>,
    )
    expect(container.textContent).toBe('Delete Amani Ngoko')

    const fenced = container.querySelectorAll('[translate="no"]')
    expect(fenced).toHaveLength(1)
    expect(fenced[0].textContent).toBe('Amani Ngoko')
    // The words around the person stay translatable — that is the whole point
    // of splitting rather than marking the parent.
    expect(container.querySelector('p')).not.toHaveAttribute('translate')
  })

  it('fences only the people, not the other values', () => {
    const { container } = render(
      <p>
        {fillNames('Requested by {name} · {date}', {
          name: 'Amani Ngoko',
          date: '12 Dec 2026',
        })}
      </p>,
    )
    expect(container.textContent).toBe('Requested by Amani Ngoko · 12 Dec 2026')
    const fenced = container.querySelectorAll('[translate="no"]')
    expect(fenced).toHaveLength(1)
    expect(fenced[0].textContent).toBe('Amani Ngoko')
  })

  it('fences a joined list of people', () => {
    const { container } = render(
      <p>{fillNames('Owed by {names}', { names: 'Amani, Neema' })}</p>,
    )
    expect(container.querySelector('[translate="no"]').textContent).toBe('Amani, Neema')
  })

  it('leaves an unfilled placeholder visible, as .replace() would', () => {
    const { container } = render(<p>{fillNames('Delete {name}', {})}</p>)
    expect(container.textContent).toBe('Delete {name}')
  })

  it('handles a template used twice, without the regex carrying state over', () => {
    const once = fillNames('Delete {name}', { name: 'Amani' })
    const twice = fillNames('Delete {name}', { name: 'Amani' })
    const { container } = render(<p>{once}{twice}</p>)
    expect(container.textContent).toBe('Delete AmaniDelete Amani')
  })
})
