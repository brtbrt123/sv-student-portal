import { describe, expect, it } from 'vitest'
import { ordinal } from '@/lib/queue/ordinal'

describe('ordinal, for "You are 25th in line" (UT-65..66)', () => {
  it('UT-65 the usual endings', () => {
    expect([1, 2, 3, 4, 5, 10].map(ordinal)).toEqual(['1st', '2nd', '3rd', '4th', '5th', '10th'])
    expect([21, 22, 23, 24, 25, 101, 102, 103].map(ordinal)).toEqual(['21st', '22nd', '23rd', '24th', '25th', '101st', '102nd', '103rd'])
  })
  it('UT-66 11, 12 and 13 (and 111 to 113) always end in th', () => {
    expect([11, 12, 13, 111, 112, 113].map(ordinal)).toEqual(['11th', '12th', '13th', '111th', '112th', '113th'])
  })
})
