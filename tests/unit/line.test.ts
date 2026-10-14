import { describe, expect, it } from 'vitest'
import { MINUTES_PER_PERSON, estimateWait, formatWait, lineSlots, needsNewNumber } from '@/lib/queue/line'

const kinds = (position: number, total: number, max?: number) => lineSlots(position, total, max).map((s) => (s.kind === 'gap' ? '...' : `${s.position}${s.kind[0]}`))

describe('wait estimate (UT-67..68)', () => {
  it('UT-67 3 to 5 minutes per person ahead, nothing when nobody is ahead', () => {
    expect(MINUTES_PER_PERSON).toEqual({ min: 3, max: 5 })
    expect(estimateWait(0)).toBeNull()
    expect(estimateWait(-2)).toBeNull()
    expect(estimateWait(1)).toEqual({ min: 3, max: 5 })
    expect(estimateWait(4)).toEqual({ min: 12, max: 20 })
  })
  it('UT-68 the wait is written as a range with an en dash', () => {
    expect(formatWait({ min: 12, max: 20 })).toBe('12–20 min')
    expect(formatWait({ min: 5, max: 5 })).toBe('5 min')
  })
})

describe('line positions to draw (UT-69..72)', () => {
  it('UT-69 a short line shows everybody: ahead, you, behind', () => {
    expect(kinds(1, 5)).toEqual(['1y', '2b', '3b', '4b', '5b'])
    expect(kinds(3, 3)).toEqual(['1a', '2a', '3y'])
    expect(kinds(3, 5)).toEqual(['1a', '2a', '3y', '4b', '5b'])
  })
  it('UT-70 a long line with you near the front is shortened with a gap after the shown ones', () => {
    expect(kinds(2, 20, 7)).toEqual(['1a', '2y', '3b', '4b', '5b', '6b', '...'])
  })
  it('UT-71 a long line with you far back shows the first three, a gap, then you', () => {
    expect(kinds(15, 20, 7)).toEqual(['1a', '2a', '3a', '...', '15y'])
  })
  it('UT-72 there is always exactly one "you", even if the counts disagree', () => {
    for (const [pos, total] of [[1, 1], [1, 0], [4, 2], [9, 9], [30, 12]] as const) {
      expect(lineSlots(pos, total).filter((s) => s.kind === 'you')).toHaveLength(1)
    }
  })
})

describe('needsNewNumber (UT-80..81)', () => {
  const served = '2026-10-14T05:00:00Z'
  it('UT-80 the code returns only for something newer than the last Done ticket; never served means any open item counts', () => {
    expect(needsNewNumber([], null)).toBe(false)
    expect(needsNewNumber(['2026-10-14T01:00:00Z'], null)).toBe(true)
    expect(needsNewNumber(['2026-10-14T01:00:00Z', '2026-10-14T04:59:59Z'], served)).toBe(false)
    expect(needsNewNumber(['2026-10-14T01:00:00Z', '2026-10-14T05:00:01Z'], served)).toBe(true)
    expect(needsNewNumber(['2026-10-14T05:00:00Z'], served)).toBe(false)
  })
  it('UT-81 an unreadable time never creates a reason to queue; an unreadable served time acts as never served', () => {
    expect(needsNewNumber([null, 'not a date'], served)).toBe(false)
    expect(needsNewNumber(['2026-10-14T01:00:00Z'], 'not a date')).toBe(true)
  })
})
