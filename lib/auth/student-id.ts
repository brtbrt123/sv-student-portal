// Students sign in with their student ID (for example 2026-0001). Supabase Auth needs an email, so the
// ID is mapped to a fixed internal address. The domain is not a real mailbox; nothing is sent to it.
export const STUDENT_EMAIL_DOMAIN = 'students.pnc.test'

// A student ID is 4 digits (the year) and 4 to 6 digits (the number). It may be typed with or without
// the hyphen: 20260004 and 2026-0004 are the same ID. The stored form always has the hyphen.
export function looksLikeStudentId(input: string): boolean {
  return /^\d{4}-?\d{4,6}$/.test(input.trim())
}

export function normalizeStudentId(id: string): string {
  const t = id.trim()
  return /^\d{8,10}$/.test(t) ? `${t.slice(0, 4)}-${t.slice(4)}` : t.toLowerCase()
}

// How a student ID is shown to people: the 8 digits with no hyphen (20260001). It is stored with the hyphen.
export function formatStudentId(id: string | null | undefined): string {
  return (id ?? '').replace(/-/g, '')
}

export function studentIdToEmail(id: string): string {
  return `${normalizeStudentId(id)}@${STUDENT_EMAIL_DOMAIN}`
}
