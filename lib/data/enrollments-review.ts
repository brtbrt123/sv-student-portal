import { createClient } from '@/lib/supabase/server'
import { formatStudentId } from '@/lib/auth/student-id'

// Server-side reads for the Registrar's enrollment review. Every query runs with the signed-in user's
// own session (anon key + auth cookies), so Row Level Security does the isolation: the Registrar can
// read every enrollment and enrollment item, other roles get nothing. No server-only key is used here.
// Import from Server Components and Server Actions only.

export type EnrollmentStatus = 'Pending' | 'Approved' | 'Rejected'

export const ENROLLMENT_STATUSES: readonly EnrollmentStatus[] = ['Pending', 'Approved', 'Rejected']

type SectionInfo = {
  sectionId: number
  sectionCode: string
  subjectCode: string
  subjectTitle: string
  units: number
  schedule: string | null
  capacity: number
  /** Seats taken now: items in this section that belong to Approved enrollments. */
  taken: number
}

/** A section of one enrollment; itemId is the enrollment_items row (what dropping it needs). */
export type EnrollmentReviewSection = SectionInfo & { itemId: number }

export type EnrollmentReviewItem = {
  id: number
  studentName: string
  studentNo: string
  termLabel: string
  yearLevel: number
  status: EnrollmentStatus
  submittedAt: string
  reviewedAt: string | null
  /** Name of the Registrar staff member who decided it (null when unknown or not decided). */
  reviewedByName: string | null
  remarks: string | null
  sections: EnrollmentReviewSection[]
  totalUnits: number
}

export type EnrollmentsReviewState = { kind: 'ready'; enrollments: EnrollmentReviewItem[] } | { kind: 'error' }

const toStatus = (s: string): EnrollmentStatus =>
  (ENROLLMENT_STATUSES as readonly string[]).includes(s) ? (s as EnrollmentStatus) : 'Pending'

const unique = <T,>(values: T[]): T[] => [...new Set(values)]

// Every enrollment with its sections (Registrar only: RLS returns nothing to other roles), oldest
// submission first. Seats taken are counted from the Approved enrollments' items, which is the same rule
// the database applies at approval. Student and reviewer names are a convenience: when they cannot be
// read, a plain label is shown. Never throws.
export async function getEnrollmentsReviewState(): Promise<EnrollmentsReviewState> {
  try {
    const supabase = await createClient()
    const [enrRes, itemRes] = await Promise.all([
      supabase
        .from('enrollments')
        .select('enrollment_id, student_id, term_id, year_level, status, submitted_at, reviewed_by, reviewed_at, remarks')
        .order('submitted_at', { ascending: true })
        .order('enrollment_id', { ascending: true }),
      supabase.from('enrollment_items').select('enrollment_item_id, enrollment_id, section_id'),
    ])
    if (enrRes.error || itemRes.error) return { kind: 'error' }

    const enrollments = enrRes.data ?? []
    const items = itemRes.data ?? []

    const sectionIds = unique(items.map((i) => i.section_id))
    const termIds = unique(enrollments.map((e) => e.term_id))
    const studentIds = unique(enrollments.map((e) => e.student_id))
    const personIds = unique(
      enrollments.flatMap((e) => [e.student_id, e.reviewed_by]).filter((v): v is string => v !== null)
    )

    const [secRes, termRes, stuRes, profRes] = await Promise.all([
      sectionIds.length
        ? supabase.from('sections').select('section_id, subject_id, section_code, schedule, capacity').in('section_id', sectionIds)
        : Promise.resolve({ data: [], error: null }),
      termIds.length
        ? supabase.from('terms').select('term_id, school_year, semester').in('term_id', termIds)
        : Promise.resolve({ data: [], error: null }),
      studentIds.length
        ? supabase.from('students').select('student_id, student_number').in('student_id', studentIds)
        : Promise.resolve({ data: [], error: null }),
      personIds.length
        ? supabase.from('profiles').select('profile_id, first_name, last_name').in('profile_id', personIds)
        : Promise.resolve({ data: [], error: null }),
    ])
    // Sections and terms are the core of the screen; names are only a convenience.
    if (secRes.error || termRes.error) return { kind: 'error' }

    const sections = secRes.data ?? []
    const subjectIds = unique(sections.map((s) => s.subject_id))
    const subRes = subjectIds.length
      ? await supabase.from('subjects').select('subject_id, code, title, units').in('subject_id', subjectIds)
      : { data: [], error: null }
    if (subRes.error) return { kind: 'error' }

    const statusById = new Map(enrollments.map((e) => [e.enrollment_id, toStatus(e.status)]))
    const taken = new Map<number, number>()
    for (const i of items) {
      if (statusById.get(i.enrollment_id) === 'Approved') taken.set(i.section_id, (taken.get(i.section_id) ?? 0) + 1)
    }

    const subjects = new Map((subRes.data ?? []).map((s) => [s.subject_id, s]))
    const sectionById = new Map(
      sections.map((s) => {
        const subject = subjects.get(s.subject_id)
        const row: SectionInfo = {
          sectionId: s.section_id,
          sectionCode: s.section_code,
          subjectCode: subject?.code ?? '-',
          subjectTitle: subject?.title ?? 'Subject',
          units: subject?.units ?? 0,
          schedule: s.schedule,
          capacity: s.capacity,
          taken: taken.get(s.section_id) ?? 0,
        }
        return [s.section_id, row] as const
      })
    )
    const itemsByEnrollment = new Map<number, EnrollmentReviewSection[]>()
    for (const i of items) {
      const section = sectionById.get(i.section_id)
      if (!section) continue
      const list = itemsByEnrollment.get(i.enrollment_id) ?? []
      list.push({ ...section, itemId: i.enrollment_item_id })
      itemsByEnrollment.set(i.enrollment_id, list)
    }

    const terms = new Map((termRes.data ?? []).map((t) => [t.term_id, `${t.semester} ${t.school_year}`]))
    const numbers = new Map((stuRes.data ?? []).map((s) => [s.student_id, formatStudentId(s.student_number)]))
    const names = new Map((profRes.data ?? []).map((p) => [p.profile_id, `${p.last_name}, ${p.first_name}`]))

    const result: EnrollmentReviewItem[] = enrollments.map((e) => {
      const list = (itemsByEnrollment.get(e.enrollment_id) ?? []).slice().sort((a, b) => a.subjectCode.localeCompare(b.subjectCode))
      return {
        id: e.enrollment_id,
        studentName: names.get(e.student_id) ?? 'Student',
        studentNo: numbers.get(e.student_id) ?? '',
        termLabel: terms.get(e.term_id) ?? 'Term',
        yearLevel: e.year_level,
        status: toStatus(e.status),
        submittedAt: e.submitted_at,
        reviewedAt: e.reviewed_at,
        reviewedByName: e.reviewed_by ? (names.get(e.reviewed_by) ?? null) : null,
        remarks: e.remarks,
        sections: list,
        totalUnits: list.reduce((sum, s) => sum + s.units, 0),
      }
    })
    return { kind: 'ready', enrollments: result }
  } catch {
    return { kind: 'error' }
  }
}
