import { describe, expect, it } from 'vitest'
import { NOT_ALLOWED, queueErrorMessage } from '@/lib/data/db-errors'

describe('queue: database error to message (UT-61..64)', () => {
  it('UT-61 an already queued student gets their ticket label in the message', () => {
    expect(queueErrorMessage('P0001', 'already queued: #8124231')).toBe('This student already has ticket #8124231 in the queue.')
  })
  it('UT-62 a label that does not look like a label is not echoed back', () => {
    const msg = queueErrorMessage('P0001', 'already queued: <script>alert(1)</script>')
    expect(msg).toBe('This student already has a ticket in the queue.')
    expect(msg).not.toContain('script')
  })
  it('UT-63 finish first, closed queue, busy queue and a changed ticket each have their own message', () => {
    expect(queueErrorMessage('P0001', 'finish first: #1000007')).toContain('Ticket #1000007 is still being served')
    expect(queueErrorMessage('P0001', 'finish first: ???')).toContain('A ticket is still being served')
    expect(queueErrorMessage('P0001', 'queue closed: Enrollment')).toBe('This queue is closed right now.')
    expect(queueErrorMessage('P0001', 'queue busy: try again')).toContain('Please press Approve again')
    expect(queueErrorMessage('P0001', 'bad ticket change: Done -> Waiting')).toContain('Reload the page')
  })
  it('UT-64 not an active student, a permission error and an unknown error', () => {
    expect(queueErrorMessage('22023', 'invalid ticket request: not a student')).toContain('not an active student')
    expect(queueErrorMessage('42501', 'not allowed: x')).toBe(NOT_ALLOWED)
    const unknown = queueErrorMessage('XX000', 'relation "queue_tickets" does not exist')
    expect(unknown).toBe('We could not update the queue. Please try again in a few minutes.')
    expect(unknown).not.toContain('relation')
  })
})
