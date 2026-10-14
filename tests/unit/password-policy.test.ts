import { describe, expect, it } from 'vitest'
import {
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
  STRONG_LENGTH,
  passwordProblem,
  passwordRules,
  passwordStrength,
} from '@/lib/auth/password-policy'

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

describe('password strength meter (UT-91..93)', () => {
  it('UT-91 nothing typed shows no level; one to two rules is Weak, three is Fair, all four is Good, 12 or more is Strong', () => {
    expect(passwordStrength('')).toEqual({ level: 0, label: '', note: null })
    expect(passwordStrength('abc').level).toBe(1)
    expect(passwordStrength('tomatoes1').level).toBe(1)
    expect(passwordStrength('Tomatoes1').level).toBe(2)
    expect(passwordStrength('Tomato#12').level).toBe(3)
    expect(passwordStrength('Tomato#12').label).toBe('Good')
    expect(STRONG_LENGTH).toBe(12)
    expect(passwordStrength('Portal#2026x').level).toBe(4)
    expect(passwordStrength('Portal#2026x').label).toBe('Strong')
  })
  it('UT-92 a Good password says how to make it strong; a Strong one has no note', () => {
    expect(passwordStrength('Portal#26').note).toContain('12 or more')
    expect(passwordStrength('Portal#2026x').note).toBeNull()
  })
  it('UT-93 a common word or run, or too few different characters, is Weak even when every rule is met', () => {
    expect(passwordStrength('Password1!').level).toBe(1)
    expect(passwordStrength('Password1!').note).toContain('common')
    expect(passwordStrength('Qwerty#12345').level).toBe(1)
    expect(passwordStrength('Aaaaaaa1!').level).toBe(1)
    expect(passwordStrength('Aaaaaaa1!').note).toContain('few different')
  })
})
