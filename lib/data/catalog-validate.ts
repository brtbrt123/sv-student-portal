// Pure validators for the Academic setup forms (terms, programs, subjects, sections). No database and no
// session, so they can be unit tested. The database is still the final gate (check constraints, column
// grants, RLS); these only give friendly messages first. Each returns { ok: true, value } or { ok: false, message }.

export type Checked<T> = { ok: true; value: T } | { ok: false; message: string }

export const SEMESTERS = ['1st', '2nd', 'Summer'] as const
export type Semester = (typeof SEMESTERS)[number]

export const MAX_CODE = 20
export const MAX_NAME = 120
export const MAX_SCHEDULE = 60
export const MIN_UNITS = 0
export const MAX_UNITS = 6
export const MIN_CAPACITY = 1
export const MAX_CAPACITY = 1000

const SCHOOL_YEAR_RE = /^\d{4}-\d{4}$/
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/
const INTEGER_RE = /^\d+$/

const fail = (message: string): { ok: false; message: string } => ({ ok: false, message })

/** A positive whole number id from a form field, or null. */
export function parseId(raw: unknown): number | null {
  const text = String(raw ?? '').trim()
  if (!INTEGER_RE.test(text)) return null
  const n = Number(text)
  return Number.isSafeInteger(n) && n > 0 ? n : null
}

/** A real calendar date written YYYY-MM-DD, or null. */
export function parseDate(raw: unknown): string | null {
  const text = String(raw ?? '').trim()
  const m = DATE_RE.exec(text)
  if (!m) return null
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])]
  const date = new Date(Date.UTC(y, mo - 1, d))
  const real = date.getUTCFullYear() === y && date.getUTCMonth() === mo - 1 && date.getUTCDate() === d
  return real ? text : null
}

function checkText(raw: unknown, label: string, max: number): Checked<string> {
  const text = String(raw ?? '').trim()
  if (!text) return fail(`Enter the ${label}.`)
  if (text.length > max) return fail(`The ${label} is too long (${max} characters at most).`)
  return { ok: true, value: text }
}

export type TermInput = { schoolYear: string; semester: Semester; startDate: string; endDate: string }

export function validateTerm(raw: { schoolYear?: unknown; semester?: unknown; startDate?: unknown; endDate?: unknown }): Checked<TermInput> {
  const schoolYear = String(raw.schoolYear ?? '').trim()
  if (!SCHOOL_YEAR_RE.test(schoolYear)) return fail('Write the school year like 2026-2027.')
  const [a, b] = schoolYear.split('-').map(Number)
  if (b !== a + 1) return fail('The school year must cover two years in a row, for example 2026-2027.')
  const semester = String(raw.semester ?? '').trim()
  if (!(SEMESTERS as readonly string[]).includes(semester)) return fail('Choose the semester: 1st, 2nd or Summer.')
  const startDate = parseDate(raw.startDate)
  if (!startDate) return fail('Enter a valid start date.')
  const endDate = parseDate(raw.endDate)
  if (!endDate) return fail('Enter a valid end date.')
  if (endDate <= startDate) return fail('The end date must be after the start date.')
  return { ok: true, value: { schoolYear, semester: semester as Semester, startDate, endDate } }
}

export type ProgramInput = { code: string; name: string }

export function validateProgram(raw: { code?: unknown; name?: unknown }): Checked<ProgramInput> {
  const code = checkText(raw.code, 'program code', MAX_CODE)
  if (!code.ok) return code
  const name = checkText(raw.name, 'program name', MAX_NAME)
  if (!name.ok) return name
  return { ok: true, value: { code: code.value, name: name.value } }
}

export type SubjectInput = { code: string; title: string; units: number }

export function validateSubject(raw: { code?: unknown; title?: unknown; units?: unknown }): Checked<SubjectInput> {
  const code = checkText(raw.code, 'subject code', MAX_CODE)
  if (!code.ok) return code
  const title = checkText(raw.title, 'subject title', MAX_NAME)
  if (!title.ok) return title
  const unitsText = String(raw.units ?? '').trim()
  const units = INTEGER_RE.test(unitsText) ? Number(unitsText) : NaN
  if (!Number.isInteger(units) || units < MIN_UNITS || units > MAX_UNITS) {
    return fail(`Units must be a whole number from ${MIN_UNITS} to ${MAX_UNITS}.`)
  }
  return { ok: true, value: { code: code.value, title: title.value, units } }
}

export type SectionInput = { sectionCode: string; schedule: string; capacity: number }

export function validateSection(raw: { sectionCode?: unknown; schedule?: unknown; capacity?: unknown }): Checked<SectionInput> {
  const sectionCode = checkText(raw.sectionCode, 'section code', MAX_CODE)
  if (!sectionCode.ok) return sectionCode
  const schedule = checkText(raw.schedule, 'schedule', MAX_SCHEDULE)
  if (!schedule.ok) return schedule
  const capacityText = String(raw.capacity ?? '').trim()
  const capacity = INTEGER_RE.test(capacityText) ? Number(capacityText) : NaN
  if (!Number.isInteger(capacity) || capacity < MIN_CAPACITY || capacity > MAX_CAPACITY) {
    return fail(`Capacity must be a whole number from ${MIN_CAPACITY} to ${MAX_CAPACITY}.`)
  }
  return { ok: true, value: { sectionCode: sectionCode.value, schedule: schedule.value, capacity } }
}
