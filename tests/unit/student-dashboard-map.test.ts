import { describe, expect, it } from 'vitest'
import {
  formatClock,
  gwaBarValue,
  gwaYTicks,
  parseSchedule,
  pickNextClass,
  secondsUntilStart,
  shortTermLabel,
} from '@/lib/data/student-dashboard-map'

describe('parseSchedule', () => {
  it('UT-122 reads days and a 24-hour style range without AM/PM', () => {
    expect(parseSchedule('MWF 8:00-9:00')).toEqual({ days: [1, 3, 5], startMin: 480, endMin: 540 })
  })
  it('UT-123 reads TTh with AM and half hours', () => {
    expect(parseSchedule('TTh 9-10:30 AM')).toEqual({ days: [2, 4], startMin: 540, endMin: 630 })
  })
  it('UT-124 treats 1 to 6 without AM/PM as afternoon and returns null for unreadable text', () => {
    expect(parseSchedule('MW 1-2:30')).toEqual({ days: [1, 3], startMin: 780, endMin: 870 })
    expect(parseSchedule('Schedule to be announced')).toBeNull()
    expect(parseSchedule(null)).toBeNull()
  })
})

describe('next class', () => {
  const meeting = { days: [1, 3, 5], startMin: 480, endMin: 540 }
  it('UT-125 counts down to a later class today', () => {
    expect(secondsUntilStart(meeting, { weekday: 1, minutes: 7 * 60, seconds: 0 })).toBe(3600)
  })
  it('UT-126 moves to the next class day once today is over', () => {
    expect(secondsUntilStart(meeting, { weekday: 1, minutes: 9 * 60, seconds: 0 })).toBe(86400 * 2 - 3600)
  })
  it('UT-127 picks the soonest class and skips unreadable schedules', () => {
    const next = pickNextClass(
      [
        { code: 'A', title: 'A', schedule: 'TBA' },
        { code: 'B', title: 'B', schedule: 'MWF 10-11 AM' },
        { code: 'C', title: 'C', schedule: 'MWF 8-9 AM' },
      ],
      { weekday: 1, minutes: 7 * 60, seconds: 0 }
    )
    expect(next).toMatchObject({ code: 'C', startsAt: '8:00 AM', seconds: 3600 })
    expect(formatClock(13 * 60)).toBe('1:00 PM')
  })
})

describe('GWA helpers', () => {
  it('UT-128 labels terms and scales bars', () => {
    expect(shortTermLabel('1st Semester', '2025-2026')).toBe('S1 25')
    expect(gwaBarValue(1.75)).toBe(1.5)
    expect(gwaBarValue(5)).toBe(0.05)
    expect(gwaYTicks([2, 5])).toEqual([1, 2, 3, 4, 5])
    expect(gwaYTicks([2, 2.5])).toEqual([1, 1.5, 2, 2.5, 3])
  })
})
