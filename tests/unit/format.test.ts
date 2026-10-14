import { describe, expect, it } from 'vitest'
import { formatDateOnly, formatPeso, formatTimestamp, plural } from '@/components/cashier/format'

describe('formatPeso (UT-01..04)', () => {
  it('UT-01 whole pesos have no decimals', () => {
    expect(formatPeso(1500)).toBe('₱1,500')
  })
  it('UT-02 centavos show two decimals', () => {
    expect(formatPeso(1500.5)).toBe('₱1,500.50')
  })
  it('UT-03 zero', () => {
    expect(formatPeso(0)).toBe('₱0')
  })
  it('UT-04 large amount keeps thousands separators and centavos', () => {
    expect(formatPeso(1234567.89)).toBe('₱1,234,567.89')
  })
})

describe('formatTimestamp, Asia/Manila (UT-05..07)', () => {
  it('UT-05 16:00 UTC is already the next day in Manila (UTC+8)', () => {
    expect(formatTimestamp('2026-09-20T16:00:00Z')).toBe('Sep 21, 2026')
  })
  it('UT-06 one second earlier is still the same Manila day', () => {
    expect(formatTimestamp('2026-09-20T15:59:59Z')).toBe('Sep 20, 2026')
  })
  it('UT-07 an invalid timestamp gives a dash, not "Invalid Date"', () => {
    expect(formatTimestamp('not a date')).toBe('-')
  })
})

describe('formatDateOnly (UT-08..10)', () => {
  it('UT-08 a plain date keeps its day', () => {
    expect(formatDateOnly('2026-09-20')).toBe('Sep 20, 2026')
  })
  it('UT-09 a timestamp is cut to its date part, the day never shifts', () => {
    expect(formatDateOnly('2026-09-20T23:30:00+00:00')).toBe('Sep 20, 2026')
  })
  it('UT-10 invalid input gives a dash', () => {
    expect(formatDateOnly('garbage')).toBe('-')
  })
})

describe('plural (UT-11)', () => {
  it('UT-11 singular, plural and a custom plural', () => {
    expect(plural(1, 'item')).toBe('1 item')
    expect(plural(2, 'item')).toBe('2 items')
    expect(plural(0, 'class', 'classes')).toBe('0 classes')
  })
})
