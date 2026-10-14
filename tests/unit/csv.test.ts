import { describe, expect, it } from 'vitest'
import { csvCell } from '@/lib/csv'

describe('csvCell, the audit log formula guard (UT-12..16)', () => {
  it('UT-12 a cell starting with = is prefixed with an apostrophe so no formula runs', () => {
    expect(csvCell('=SUM(A1:A9)')).toBe(`"'=SUM(A1:A9)"`)
  })
  it('UT-13 the other formula starters + - @ are guarded too', () => {
    expect(csvCell('+1')).toBe(`"'+1"`)
    expect(csvCell('-2')).toBe(`"'-2"`)
    expect(csvCell('@cmd')).toBe(`"'@cmd"`)
  })
  it('UT-14 a leading tab or carriage return is guarded', () => {
    expect(csvCell('\tx')).toBe(`"'\tx"`)
    expect(csvCell('\rx')).toBe(`"'\rx"`)
  })
  it('UT-15 plain text is only quoted', () => {
    expect(csvCell('Insert')).toBe('"Insert"')
  })
  it('UT-16 double quotes inside a cell are doubled', () => {
    expect(csvCell('say "hi"')).toBe('"say ""hi"""')
  })
})
