import { describe, it, expect } from 'vitest'
import { formatTZS, formatDate, formatMonth } from './format'

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

describe('formatDate', () => {
  it('formats a plain date column', () => {
    expect(formatDate('2026-06-30')).toBe('30 Jun 2026')
  })

  // The admin dashboard crash: reviewed_at is timestamptz, and appending
  // 'T00:00:00Z' to a value that already carried a time made Intl throw.
  it('formats a full timestamptz without throwing', () => {
    expect(formatDate('2026-06-30T08:14:32.123456+00:00')).toBe('30 Jun 2026')
  })

  it('does not drift across the browser timezone', () => {
    expect(formatDate('2026-06-30T23:30:00+00:00')).toBe('30 Jun 2026')
  })

  it('returns empty for missing or unparseable input', () => {
    expect(formatDate(null)).toBe('')
    expect(formatDate(undefined)).toBe('')
    expect(formatDate('')).toBe('')
    expect(formatDate('not-a-date')).toBe('')
  })
})

describe('formatMonth', () => {
  it('formats a month built from YYYY-MM', () => {
    expect(formatMonth('2026-06-01')).toBe('Jun 2026')
  })

  it('formats a full timestamptz without throwing', () => {
    expect(formatMonth('2026-06-30T08:14:32.123456+00:00')).toBe('Jun 2026')
  })

  it('returns empty for missing or unparseable input', () => {
    expect(formatMonth(null)).toBe('')
    expect(formatMonth('not-a-date')).toBe('')
  })
})
