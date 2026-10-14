import { describe, expect, it } from 'vitest'
import { QR_WINDOW_SECONDS, createQueueToken, verifyQueueToken } from '@/lib/queue/qr-token'

const SECRET = 'test-secret-test-secret-test-secret-12345'
const OTHER_SECRET = 'another-secret-another-secret-another-9876'
const STUDENT = '3f2b8a14-6c1d-4e7a-9b55-0a1c2d3e4f50'
const T0 = Date.UTC(2026, 9, 13, 8, 0, 0) // 2026-10-13 08:00:00 UTC, the start of a window
const SEC = 1000

describe('queue QR token (UT-50..60)', () => {
  it('UT-50 a fresh code verifies and returns the same student', () => {
    const { token } = createQueueToken(STUDENT, SECRET, T0)
    expect(verifyQueueToken(token, SECRET, T0)).toEqual({ ok: true, studentId: STUDENT })
  })
  it('UT-51 the code has the expected shape', () => {
    const { token } = createQueueToken(STUDENT, SECRET, T0)
    expect(token).toMatch(/^CUQ1\.[0-9a-f-]{36}\.\d+\.[A-Za-z0-9_-]{22}$/)
  })
  it('UT-52 the code changes with every 30-second window', () => {
    const a = createQueueToken(STUDENT, SECRET, T0).token
    const sameWindow = createQueueToken(STUDENT, SECRET, T0 + 29 * SEC).token
    const nextWindow = createQueueToken(STUDENT, SECRET, T0 + 30 * SEC).token
    expect(sameWindow).toBe(a)
    expect(nextWindow).not.toBe(a)
  })
  it('UT-53 refreshInSeconds is the time left in the window', () => {
    expect(createQueueToken(STUDENT, SECRET, T0).refreshInSeconds).toBe(QR_WINDOW_SECONDS)
    expect(createQueueToken(STUDENT, SECRET, T0 + 20 * SEC).refreshInSeconds).toBe(10)
    expect(createQueueToken(STUDENT, SECRET, T0 + 29.2 * SEC).refreshInSeconds).toBe(1)
  })
  it('UT-54 a code is still accepted in the next window (grace, so a scan at the edge still works)', () => {
    const { token } = createQueueToken(STUDENT, SECRET, T0 + 29 * SEC) // made in window 0
    expect(verifyQueueToken(token, SECRET, T0 + 31 * SEC)).toEqual({ ok: true, studentId: STUDENT }) // window 1
    expect(verifyQueueToken(token, SECRET, T0 + 59 * SEC).ok).toBe(true) // still window 1
  })
  it('UT-55 a code two windows old is expired, so a screenshot stops working', () => {
    const { token } = createQueueToken(STUDENT, SECRET, T0 + 29 * SEC) // made in window 0
    expect(verifyQueueToken(token, SECRET, T0 + 61 * SEC)).toEqual({ ok: false, reason: 'expired' }) // window 2
    expect(verifyQueueToken(token, SECRET, T0 + 5 * 60 * SEC)).toEqual({ ok: false, reason: 'expired' })
  })
  it('UT-56 a code from a window far in the future is rejected', () => {
    const { token } = createQueueToken(STUDENT, SECRET, T0 + 10 * 60 * SEC)
    expect(verifyQueueToken(token, SECRET, T0)).toEqual({ ok: false, reason: 'expired' })
  })
  it('UT-57 a code signed with another secret is rejected', () => {
    const { token } = createQueueToken(STUDENT, OTHER_SECRET, T0)
    expect(verifyQueueToken(token, SECRET, T0)).toEqual({ ok: false, reason: 'bad-signature' })
  })
  it('UT-58 changing the student id or the window breaks the signature', () => {
    const { token } = createQueueToken(STUDENT, SECRET, T0)
    const [prefix, , windowIndex, signature] = token.split('.')
    const otherStudent = [prefix, '00000000-0000-4000-8000-000000000000', windowIndex, signature].join('.')
    const otherWindow = [prefix, STUDENT, String(Number(windowIndex) + 1), signature].join('.')
    expect(verifyQueueToken(otherStudent, SECRET, T0)).toEqual({ ok: false, reason: 'bad-signature' })
    expect(verifyQueueToken(otherWindow, SECRET, T0)).toEqual({ ok: false, reason: 'bad-signature' })
  })
  it('UT-59 malformed input is rejected without throwing', () => {
    for (const bad of ['', 'hello', 'CUQ1.x.y.z', `CUQ2.${STUDENT}.1.${'a'.repeat(22)}`, 'x'.repeat(500), `CUQ1.${STUDENT}.1.short`]) {
      expect(verifyQueueToken(bad, SECRET, T0)).toEqual({ ok: false, reason: 'malformed' })
    }
  })
  it('UT-60 the input is validated: no code is made for a bad id or a short secret', () => {
    expect(() => createQueueToken('not-a-uuid', SECRET, T0)).toThrow()
    expect(() => createQueueToken(STUDENT, 'short', T0)).toThrow()
    const { token } = createQueueToken(STUDENT, SECRET, T0)
    expect(verifyQueueToken(token, 'short', T0)).toEqual({ ok: false, reason: 'bad-signature' })
  })
})
