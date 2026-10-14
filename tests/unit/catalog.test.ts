import { describe, expect, it } from 'vitest'
import { parseDate, parseId, validateProgram, validateSection, validateSubject, validateTerm } from '@/lib/data/catalog-validate'
import { catalogErrorMessage, CATALOG_GENERIC, CATALOG_NOT_ALLOWED } from '@/lib/data/catalog-errors'

const term = { schoolYear: '2026-2027', semester: '1st', startDate: '2026-08-01', endDate: '2026-12-15' }

describe('academic setup validators and error mapper (UT-100..109)', () => {
  it('UT-100 a good term passes and is trimmed', () => {
    const r = validateTerm({ ...term, schoolYear: ' 2026-2027 ' })
    expect(r).toEqual({ ok: true, value: { schoolYear: '2026-2027', semester: '1st', startDate: '2026-08-01', endDate: '2026-12-15' } })
  })
  it('UT-101 a term needs a YYYY-YYYY school year of two years in a row, and a known semester', () => {
    expect(validateTerm({ ...term, schoolYear: '2026' }).ok).toBe(false)
    expect(validateTerm({ ...term, schoolYear: '2026-2028' }).ok).toBe(false)
    expect(validateTerm({ ...term, semester: '3rd' }).ok).toBe(false)
    expect(validateTerm({ ...term, semester: 'Summer' }).ok).toBe(true)
  })
  it('UT-102 a term end date must be after the start date and dates must be real', () => {
    expect(validateTerm({ ...term, endDate: '2026-08-01' }).ok).toBe(false)
    expect(validateTerm({ ...term, endDate: '2026-07-01' }).ok).toBe(false)
    expect(validateTerm({ ...term, startDate: '2026-02-30' }).ok).toBe(false)
    expect(parseDate('2026-02-28')).toBe('2026-02-28')
    expect(parseDate('28/02/2026')).toBeNull()
  })
  it('UT-103 subject units must be a whole number from 0 to 6', () => {
    const base = { code: 'IT101', title: 'Intro to IT' }
    expect(validateSubject({ ...base, units: '0' }).ok).toBe(true)
    expect(validateSubject({ ...base, units: '6' }).ok).toBe(true)
    expect(validateSubject({ ...base, units: '7' }).ok).toBe(false)
    expect(validateSubject({ ...base, units: '-1' }).ok).toBe(false)
    expect(validateSubject({ ...base, units: '2.5' }).ok).toBe(false)
    expect(validateSubject({ ...base, units: '' }).ok).toBe(false)
  })
  it('UT-104 section capacity must be a whole number from 1 to 1000', () => {
    const base = { sectionCode: 'A', schedule: 'MWF 8-9' }
    expect(validateSection({ ...base, capacity: '1' }).ok).toBe(true)
    expect(validateSection({ ...base, capacity: '1000' }).ok).toBe(true)
    expect(validateSection({ ...base, capacity: '0' }).ok).toBe(false)
    expect(validateSection({ ...base, capacity: '1001' }).ok).toBe(false)
    expect(validateSection({ ...base, capacity: 'abc' }).ok).toBe(false)
  })
  it('UT-105 required text is trimmed, must not be empty, and has a length limit', () => {
    expect(validateProgram({ code: '  BSIT ', name: ' Information Technology ' })).toEqual({
      ok: true,
      value: { code: 'BSIT', name: 'Information Technology' },
    })
    expect(validateProgram({ code: '   ', name: 'x' }).ok).toBe(false)
    expect(validateProgram({ code: 'BSIT', name: 'x'.repeat(121) }).ok).toBe(false)
    expect(validateSection({ sectionCode: 'A', schedule: '', capacity: '30' }).ok).toBe(false)
  })
  it('UT-106 parseId accepts only positive whole numbers', () => {
    expect(parseId('12')).toBe(12)
    expect(parseId('0')).toBeNull()
    expect(parseId('1.5')).toBeNull()
    expect(parseId('-3')).toBeNull()
    expect(parseId(null)).toBeNull()
  })
  it('UT-107 duplicate (23505) and permission (42501) errors become plain sentences', () => {
    expect(catalogErrorMessage('23505', 'duplicate key value violates unique constraint "programs_code_key"')).toBe(
      'That code is already used. Use a different code.'
    )
    expect(catalogErrorMessage('23505', 'duplicate key ... "uq_terms_one_current_term"')).toBe('Another term is already marked as the current term.')
    expect(catalogErrorMessage('42501', 'permission denied for table terms')).toBe(CATALOG_NOT_ALLOWED)
  })
  it('UT-108 check errors (23514) name the rule that failed', () => {
    expect(catalogErrorMessage('23514', 'violates check constraint "terms_dates_order"')).toMatch(/end date/i)
    expect(catalogErrorMessage('23514', 'violates check constraint "sections_capacity_check"')).toMatch(/capacity/i)
    expect(catalogErrorMessage('23514', 'violates check constraint "subjects_units_check"')).toMatch(/units/i)
  })
  it('UT-109 an unknown error gives the generic message and never leaks database text', () => {
    const text = catalogErrorMessage('XX000', 'relation public.terms secret detail')
    expect(text).toBe(CATALOG_GENERIC)
    expect(catalogErrorMessage(undefined, undefined)).toBe(CATALOG_GENERIC)
    expect(catalogErrorMessage('P0001', 'secret internal text')).not.toContain('secret')
  })
})
