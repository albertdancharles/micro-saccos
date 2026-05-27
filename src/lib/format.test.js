import { describe, it, expect } from 'vitest'
import { formatTZS } from './format'

describe('formatTZS', () => {
  it('formats whole TZS with no decimal places', () => {
    // Locale/ICU may vary the symbol and separator, so compare digits only.
    expect(formatTZS(10000).replace(/[^\d]/g, '')).toBe('10000')
  })

  it('treats non-numeric input as zero', () => {
    expect(formatTZS(undefined).replace(/[^\d]/g, '')).toBe('0')
    expect(formatTZS(null).replace(/[^\d]/g, '')).toBe('0')
  })
})
