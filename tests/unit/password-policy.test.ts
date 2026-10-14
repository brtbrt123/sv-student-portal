import { describe, expect, it } from 'vitest'
import { PASSWORD_MAX_LENGTH, PASSWORD_MIN_LENGTH, passwordProblem, passwordRules } from '@/lib/auth/password-policy'

describe('password policy (UT-88..90)', () => {
  it('UT-88 accepts 8 characters with a capital letter, a number and a special character', () => {
    expect(PASSWORD_MIN_LENGTH).toBe(8)
    expect(passwordProblem('Abcdef1!')).toBeNull()
    expect(passwordProblem('Portal#2026')).toBeNull()
    expect(passwordProblem('x'.repeat(PASSWORD_MAX_LENGTH - 3) + 'A1!')).toBeNull()
  })
  it('UT-89 names the first rule that is broken, in the order length, capital, number, special', () => {
    expect(passwordProblem('Ab1!')).toBe('Use at least 8 characters.')
    expect(passwordProblem('abcdefg1!')).toBe('Add at least one capital letter.')
    expect(passwordProblem('Abcdefgh!')).toBe('Add at least one number.')
    expect(passwordProblem('Abcdefg12')).toBe('Add at least one special character, such as ! ? # or @.')
    expect(passwordProblem('abcdefgh')).toBe('Add at least one capital letter.')
  })
  it('UT-90 counts a space as nothing special, rejects over 72 characters, and lists the four rules for the form', () => {
    expect(passwordProblem('Abcdef1 ')).toBe('Add at least one special character, such as ! ? # or @.')
    expect(passwordProblem('Aa1!' + 'x'.repeat(PASSWORD_MAX_LENGTH))).toBe(`Use ${PASSWORD_MAX_LENGTH} characters at most.`)
    expect(passwordRules('Abcdef1!').map((r) => [r.id, r.ok])).toEqual([
      ['length', true],
      ['upper', true],
      ['digit', true],
      ['special', true],
    ])
    expect(passwordRules('').every((r) => !r.ok)).toBe(true)
  })
})
