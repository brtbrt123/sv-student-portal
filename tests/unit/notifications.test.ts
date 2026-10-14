import { describe, expect, it } from 'vitest'
import { kindIcon } from '@/lib/notifications/kind'
import { formatWhen, unreadLabel } from '@/lib/notifications/time'

// 2026-10-13 15:00 in Manila = 07:00 UTC
const NOW = new Date('2026-10-13T07:00:00Z')
const ago = (ms: number) => new Date(NOW.getTime() - ms).toISOString()
const MIN = 60_000
const HOUR = 3_600_000

describe('formatWhen (UT-73..76)', () => {
  it('UT-73 under a minute, and a time slightly in the future, read "Just now"', () => {
    expect(formatWhen(ago(10_000), NOW)).toBe('Just now')
    expect(formatWhen(ago(-30_000), NOW)).toBe('Just now')
  })
  it('UT-74 minutes and hours up to six hours', () => {
    expect(formatWhen(ago(5 * MIN), NOW)).toBe('5 min ago')
    expect(formatWhen(ago(59 * MIN), NOW)).toBe('59 min ago')
    expect(formatWhen(ago(2 * HOUR + 10 * MIN), NOW)).toBe('2 h ago')
  })
  it('UT-75 earlier today and yesterday show the Manila clock time', () => {
    expect(formatWhen('2026-10-13T00:05:00Z', NOW)).toBe('Today, 8:05 AM') // 08:05 in Manila, 6 h 55 min ago
    expect(formatWhen('2026-10-12T07:30:00Z', NOW)).toBe('Yesterday, 3:30 PM')
  })
  it('UT-76 older dates show the day, with the year only when it is another year; a bad date gives nothing', () => {
    expect(formatWhen('2026-10-01T02:00:00Z', NOW)).toBe('Oct 1, 10:00 AM')
    expect(formatWhen('2025-12-31T02:00:00Z', NOW)).toBe('Dec 31, 2025, 10:00 AM')
    expect(formatWhen('not a date', NOW)).toBe('')
  })
})

describe('unreadLabel and kindIcon (UT-77..78)', () => {
  it('UT-77 the badge text: nothing for 0, the number, and 99+ from 100', () => {
    expect([0, -1, NaN].map(unreadLabel)).toEqual(['', '', ''])
    expect([1, 7, 99].map(unreadLabel)).toEqual(['1', '7', '99'])
    expect([100, 250].map(unreadLabel)).toEqual(['99+', '99+'])
  })
  it('UT-78 a kind code maps to its icon, an unknown kind to the plain bell', () => {
    expect(kindIcon('queue_turn')).toBe('queue')
    expect(kindIcon('enrollment_decided')).toBe('enrollment')
    expect(kindIcon('application_submitted')).toBe('users')
    expect(kindIcon('document_status')).toBe('documents')
    expect(kindIcon('clearance_cleared')).toBe('clearance')
    expect(kindIcon('hold_placed')).toBe('holds')
    expect(kindIcon('grade_posted')).toBe('grades')
    expect(kindIcon('something_new')).toBe('notifications')
  })
})
