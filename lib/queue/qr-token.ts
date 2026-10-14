import { createHmac, timingSafeEqual } from 'node:crypto'

// The rotating QR code on the student's enrollment page. The code is a signed token, not a stored value:
//
//   CUQ1.<student id>.<time window>.<signature>
//
// A time window is 15 seconds long. The signature is an HMAC-SHA256 over the student id and the window,
// made with a server-only secret (QUEUE_QR_SECRET), so a code cannot be forged. A code works in the window
// it was made in and in the next one, so a screenshot stops working after 30 seconds at most. One window
// ahead is also accepted, for clock differences between servers. Pure functions: no database, no
// environment. The secret is passed in, so tests can use their own.

export const QR_PREFIX = 'CUQ1'
export const QR_WINDOW_SECONDS = 15
export const QR_MIN_SECRET_LENGTH = 32

const SIGNATURE_LENGTH = 22
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const SIGNATURE_RE = /^[A-Za-z0-9_-]{22}$/
const MAX_TOKEN_LENGTH = 120

export type QueueToken = { token: string; refreshInSeconds: number }

export type QueueTokenResult =
  | { ok: true; studentId: string }
  | { ok: false; reason: 'malformed' | 'bad-signature' | 'expired' }

const windowOf = (ms: number): number => Math.floor(ms / 1000 / QR_WINDOW_SECONDS)

function sign(secret: string, studentId: string, window: number): string {
  return createHmac('sha256', secret).update(`queue-qr:${studentId}:${window}`).digest('base64url').slice(0, SIGNATURE_LENGTH)
}

// Makes the code for one student at one moment. `refreshInSeconds` is how long until the 15-second window
// ends: the page asks for a new code then.
export function createQueueToken(studentId: string, secret: string, now: number = Date.now()): QueueToken {
  if (!UUID_RE.test(studentId)) throw new Error('A queue code needs a student id.')
  if (secret.length < QR_MIN_SECRET_LENGTH) throw new Error('The queue secret is too short.')
  const id = studentId.toLowerCase()
  const window = windowOf(now)
  const endsAt = (window + 1) * QR_WINDOW_SECONDS * 1000
  return {
    token: `${QR_PREFIX}.${id}.${window}.${sign(secret, id, window)}`,
    refreshInSeconds: Math.max(1, Math.ceil((endsAt - now) / 1000)),
  }
}

// Checks a scanned code. The signature is checked first, so a forged code is never told apart from a
// valid but old one. Accepted: the current window, the one before it, and one ahead (clock skew).
export function verifyQueueToken(token: string, secret: string, now: number = Date.now()): QueueTokenResult {
  if (typeof token !== 'string' || token.length === 0 || token.length > MAX_TOKEN_LENGTH) return { ok: false, reason: 'malformed' }
  const parts = token.split('.')
  if (parts.length !== 4 || parts[0] !== QR_PREFIX) return { ok: false, reason: 'malformed' }
  const [, studentId, windowRaw, given] = parts
  if (!UUID_RE.test(studentId) || !/^\d{1,10}$/.test(windowRaw) || !SIGNATURE_RE.test(given)) {
    return { ok: false, reason: 'malformed' }
  }
  if (secret.length < QR_MIN_SECRET_LENGTH) return { ok: false, reason: 'bad-signature' }

  const id = studentId.toLowerCase()
  const window = Number(windowRaw)
  const expected = Buffer.from(sign(secret, id, window))
  const actual = Buffer.from(given)
  if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) return { ok: false, reason: 'bad-signature' }

  const current = windowOf(now)
  if (window < current - 1 || window > current + 1) return { ok: false, reason: 'expired' }
  return { ok: true, studentId: id }
}
