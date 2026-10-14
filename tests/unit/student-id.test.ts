import { describe, expect, it } from 'vitest'
import { looksLikeStudentId, normalizeStudentId, studentIdToEmail } from '@/lib/auth/student-id'

describe('student ID sign-in (UT-23..26)', () => {
  it('UT-23 an ID typed without the hyphen is stored with it', () => {
    expect(normalizeStudentId('20260004')).toBe('2026-0004')
  })
  it('UT-24 an ID with the hyphen, or with spaces around it, stays the same', () => {
    expect(normalizeStudentId('2026-0004')).toBe('2026-0004')
    expect(normalizeStudentId('  2026-0004  ')).toBe('2026-0004')
  })
  it('UT-25 the shape check accepts 4 + 4 to 6 digits, with or without the hyphen, and rejects the rest', () => {
    expect(looksLikeStudentId('2026-0004')).toBe(true)
    expect(looksLikeStudentId('20260004')).toBe(true)
    expect(looksLikeStudentId('2026-000004')).toBe(true)
    expect(looksLikeStudentId('abc')).toBe(false)
    expect(looksLikeStudentId('2026-00')).toBe(false)
    expect(looksLikeStudentId("2026-0004'; drop table profiles;--")).toBe(false)
  })
  it('UT-26 the ID maps to the fixed internal sign-in address, the same for both spellings', () => {
    expect(studentIdToEmail('20260004')).toBe('2026-0004@students.pnc.test')
    expect(studentIdToEmail('2026-0004')).toBe('2026-0004@students.pnc.test')
  })
})
