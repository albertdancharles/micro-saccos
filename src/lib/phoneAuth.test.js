import { describe, it, expect } from 'vitest'
import { firstNameOf, phoneProblem, pinProblem } from './phoneAuth'

describe('firstNameOf', () => {
  it('takes the first word, lowercased', () => {
    expect(firstNameOf('Jane Mushi')).toBe('jane')
    expect(firstNameOf('JANE MUSHI')).toBe('jane')
  })

  // The login compares this against member_first_name() in SQL, which does the same
  // btrim + split_part. Extra whitespace either side must not change the answer, or a
  // profile saved with a trailing space stops being able to sign in.
  it('ignores surrounding and repeated whitespace', () => {
    expect(firstNameOf('  Jane   Mushi  ')).toBe('jane')
  })

  it('handles a single-word name', () => {
    expect(firstNameOf('Mwalimu')).toBe('mwalimu')
  })

  it('is empty for nothing', () => {
    expect(firstNameOf('')).toBe('')
    expect(firstNameOf(null)).toBe('')
    expect(firstNameOf(undefined)).toBe('')
  })
})

describe('phoneProblem', () => {
  it('accepts the three forms an admin actually types', () => {
    expect(phoneProblem('+255712345678')).toBeNull()
    expect(phoneProblem('255712345678')).toBeNull()
    expect(phoneProblem('0712345678')).toBeNull()
  })

  it('accepts a bare 9-digit subscriber number', () => {
    expect(phoneProblem('712345678')).toBeNull()
  })

  it('ignores spaces and punctuation when counting digits', () => {
    expect(phoneProblem('+255 712 345 678')).toBeNull()
    expect(phoneProblem('0712-345-678')).toBeNull()
  })

  it('rejects empty and too-short entries', () => {
    expect(phoneProblem('')).toMatch(/Enter your phone number/)
    expect(phoneProblem(null)).toMatch(/Enter your phone number/)
    expect(phoneProblem('0712')).toMatch(/too short/)
  })

  it('rejects an over-long entry', () => {
    expect(phoneProblem('+255712345678901')).toMatch(/too long/)
  })
})

describe('pinProblem', () => {
  it('accepts 4 to 6 digits', () => {
    expect(pinProblem('4829')).toBeNull()
    expect(pinProblem('48291')).toBeNull()
    expect(pinProblem('482917')).toBeNull()
  })

  it('rejects the wrong length', () => {
    expect(pinProblem('482')).toMatch(/4 to 6 digits/)
    expect(pinProblem('4829170')).toMatch(/4 to 6 digits/)
    expect(pinProblem('')).toMatch(/4 to 6 digits/)
  })

  it('rejects anything that is not all digits', () => {
    expect(pinProblem('48a9')).toMatch(/4 to 6 digits/)
    expect(pinProblem('48 9')).toMatch(/4 to 6 digits/)
    expect(pinProblem('-482')).toMatch(/4 to 6 digits/)
  })

  // With five attempts before a lockout, the handful of PINs a guesser would try
  // first are worth refusing outright.
  it('rejects an all-same-digit PIN', () => {
    expect(pinProblem('0000')).toMatch(/all the same digit/)
    expect(pinProblem('7777')).toMatch(/all the same digit/)
    expect(pinProblem('111111')).toMatch(/all the same digit/)
  })

  it('rejects digits in a row, either direction', () => {
    expect(pinProblem('1234')).toMatch(/digits in a row/)
    expect(pinProblem('456789')).toMatch(/digits in a row/)
    expect(pinProblem('4321')).toMatch(/digits in a row/)
    expect(pinProblem('9876')).toMatch(/digits in a row/)
  })

  // The wrap-around cases the two run strings are built to cover: '01234567890'
  // contains '7890', and the descending one contains '0987'.
  it('rejects runs that wrap past zero', () => {
    expect(pinProblem('7890')).toMatch(/digits in a row/)
    expect(pinProblem('0987')).toMatch(/digits in a row/)
  })

  it('accepts a PIN that merely contains a short ascending pair', () => {
    expect(pinProblem('1259')).toBeNull()
    expect(pinProblem('3417')).toBeNull()
  })
})
