import { describe, expect, it } from 'vitest'
import { cn } from '@/lib/utils'

describe('cn, the class merger (UT-40..41)', () => {
  it('UT-40 the later Tailwind class wins over a conflicting earlier one', () => {
    expect(cn('p-2', 'p-4')).toBe('p-4')
  })
  it('UT-41 falsy values are dropped and the custom shadow sizes conflict with each other', () => {
    expect(cn('a', false && 'b', undefined, 'c')).toBe('a c')
    expect(cn('shadow-elev-sm', 'shadow-xl')).toBe('shadow-xl')
  })
})
