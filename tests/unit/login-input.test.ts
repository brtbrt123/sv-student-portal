import { describe, expect, it } from 'vitest'
import { MAX_LOGIN_NAME, MAX_LOGIN_PASSWORD, loginInputIsAcceptable } from '@/lib/auth/login-input'

describe('sign-in input shape (issue #108, SEC-03 / SEC-05; UT-82..87)', () => {
  it('UT-82 accepts an email and a student ID with a normal password', () => {
    expect(loginInputIsAcceptable('student@example.com', 'secret')).toBe(true)
    expect(loginInputIsAcceptable('2026-0001', 'secret')).toBe(true)
  })
  it('UT-83 rejects an empty name or an empty password', () => {
    expect(loginInputIsAcceptable('', 'secret')).toBe(false)
    expect(loginInputIsAcceptable('a@b.co', '')).toBe(false)
  })
  it('UT-84 rejects a name longer than the database limit and accepts exactly the limit', () => {
    expect(loginInputIsAcceptable('a'.repeat(MAX_LOGIN_NAME), 'x')).toBe(true)
    expect(loginInputIsAcceptable('a'.repeat(MAX_LOGIN_NAME + 1), 'x')).toBe(false)
  })
  it('UT-85 rejects a password longer than the limit', () => {
    expect(loginInputIsAcceptable('a@b.co', 'p'.repeat(MAX_LOGIN_PASSWORD))).toBe(true)
    expect(loginInputIsAcceptable('a@b.co', 'p'.repeat(MAX_LOGIN_PASSWORD + 1))).toBe(false)
  })
  it('UT-86 rejects control characters in the name (newline, tab, NUL)', () => {
    for (const bad of ['a@b.co\n', 'a\t@b.co', 'a\u0000@b.co', 'a\u007f@b.co']) {
      expect(loginInputIsAcceptable(bad, 'x')).toBe(false)
    }
  })
  it('UT-87 the SQL injection payloads are not special here: they are text, not rejected as SQL', () => {
    // Defence is the parameterized rpc call, not filtering. The payload is only a printable string, so the
    // shape check lets it through to the (parameterized) call, which then fails the sign-in generically.
    expect(loginInputIsAcceptable("' OR 1=1 --", "'; DROP TABLE x; --")).toBe(true)
  })
})
