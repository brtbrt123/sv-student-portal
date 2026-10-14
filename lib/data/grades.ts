import { createClient } from '@/lib/supabase/server'
import { getCurrentTerm, type CurrentTerm } from '@/lib/data/clearance'
import { formatStudentId } from '@/lib/auth/student-id'

// Server-side reads for grades. Every query runs with the signed-in user's own session (anon key +
// auth cookies), so Row Level Security does the isolation. No server-only key is used here. Import
// this file from Server Components and Server Actions only.

export type GradeResult = 'Passed' | 'Failed' | 'Incomplete' | 'Dropped'

// Result in words. Only a 5.00 is a fail; INC and DRP are not passing but are not failures either.
export function gradeResult(gradeCode: string | null, isPassing: boolean | null): GradeResult {
  if (isPassing) return 'Passed'
  if (gradeCode === 'INC') return 'Incomplete'
  if (gradeCode === 'DRP') return 'Dropped'
  return 'Failed'
}

export type StudentGrade = {
  id: string
  subjectCode: string
  subjectTitle: string
  units: number
  gradeCode: string
  numericValue: number | null
  result: GradeResult
}

export type StudentTermGrades = {
  termId: number
  label: string
  grades: StudentGrade[]
  /** Units-weighted average over subjects with a numeric grade (lower is better). Null when none. */
  gwa: number | null
  enrolledUnits: number
  earnedUnits: number
}

export type StudentGradesState = { kind: 'ready'; terms: StudentTermGrades[] } | { kind: 'error' }

// The signed-in student's posted grades from v_grades, grouped by term (newest first). Never throws.
export async function getStudentGradesState(): Promise<StudentGradesState> {
  try {
    const supabase = await createClient()
    const { data: userData } = await supabase.auth.getUser()
    const user = userData.user
    if (!user) return { kind: 'error' }

    const { data, error } = await supabase
      .from('v_grades')
      .select('grade_id, enrollment_item_id, student_id, term_id, subject_code, subject_title, units, grade_code, numeric_value, is_passing')
      .eq('student_id', user.id)
    if (error) return { kind: 'error' }

    const rows = data ?? []
    const termIds = [...new Set(rows.map((r) => r.term_id).filter((v): v is number => v !== null))]
    const { data: termRows, error: termError } = termIds.length
      ? await supabase.from('terms').select('term_id, school_year, semester').in('term_id', termIds)
      : { data: [], error: null }
    if (termError) return { kind: 'error' }
    const labels = new Map((termRows ?? []).map((t) => [t.term_id, `${t.semester} ${t.school_year}`]))

    const byTerm = new Map<number, StudentGrade[]>()
    for (const r of rows) {
      if (r.term_id === null || r.grade_code === null || r.enrollment_item_id === null) continue
      const list = byTerm.get(r.term_id) ?? []
      list.push({
        id: String(r.grade_id ?? r.enrollment_item_id),
        subjectCode: r.subject_code ?? '-',
        subjectTitle: r.subject_title ?? '-',
        units: r.units ?? 0,
        gradeCode: r.grade_code,
        numericValue: r.numeric_value,
        result: gradeResult(r.grade_code, r.is_passing),
      })
      byTerm.set(r.term_id, list)
    }

    const terms: StudentTermGrades[] = [...byTerm.entries()]
      .sort((a, b) => b[0] - a[0])
      .map(([termId, grades]) => {
        grades.sort((a, b) => a.subjectCode.localeCompare(b.subjectCode))
        const numeric = grades.filter((g) => g.numericValue !== null)
        const numericUnits = numeric.reduce((s, g) => s + g.units, 0)
        const gwa =
          numericUnits > 0 ? numeric.reduce((s, g) => s + (g.numericValue ?? 0) * g.units, 0) / numericUnits : null
        return {
          termId,
          label: labels.get(termId) ?? 'Term',
          grades,
          gwa,
          enrolledUnits: grades.reduce((s, g) => s + g.units, 0),
          earnedUnits: grades.filter((g) => g.result === 'Passed').reduce((s, g) => s + g.units, 0),
        }
      })
    return { kind: 'ready', terms }
  } catch {
    return { kind: 'error' }
  }
}

// ---------------------------------------------------------------- Registrar

export type GradeScaleOption = { code: string; description: string; isPassing: boolean }

export type EncodableItem = {
  enrollmentItemId: number
  studentName: string
  studentNo: string
  sectionId: number
  subjectCode: string
  subjectTitle: string
  sectionCode: string
  /** Current grade code, or null when none has been encoded yet. */
  gradeCode: string | null
}

export type RegistrarGradesState =
  | { kind: 'ready'; term: CurrentTerm; items: EncodableItem[]; scale: GradeScaleOption[] }
  | { kind: 'no-term' }
  | { kind: 'error' }

const fullName = (p: { first_name: string; last_name: string }) => `${p.last_name}, ${p.first_name}`

// Every enrollment item of an APPROVED enrollment in the current term, with its current grade (if any)
// and the grade scale for the dropdown. Never throws.
export async function getRegistrarGradesState(): Promise<RegistrarGradesState> {
  try {
    const supabase = await createClient()
    const term = await getCurrentTerm()
    if (!term) return { kind: 'no-term' }

    const [enrRes, scaleRes] = await Promise.all([
      supabase.from('enrollments').select('enrollment_id, student_id').eq('term_id', term.termId).eq('status', 'Approved'),
      supabase.from('grade_scale').select('grade_code, numeric_value, is_passing, description'),
    ])
    if (enrRes.error || scaleRes.error) return { kind: 'error' }

    const scale: GradeScaleOption[] = (scaleRes.data ?? [])
      .sort((a, b) => {
        // Numeric grades best to worst, then the letter codes (INC, DRP).
        if (a.numeric_value === null && b.numeric_value === null) return a.grade_code.localeCompare(b.grade_code)
        if (a.numeric_value === null) return 1
        if (b.numeric_value === null) return -1
        return a.numeric_value - b.numeric_value
      })
      .map((s) => ({ code: s.grade_code, description: s.description, isPassing: s.is_passing }))

    const enrollments = enrRes.data ?? []
    if (enrollments.length === 0) return { kind: 'ready', term, items: [], scale }
    const studentByEnrollment = new Map(enrollments.map((e) => [e.enrollment_id, e.student_id]))

    const { data: itemRows, error: itemError } = await supabase
      .from('enrollment_items')
      .select('enrollment_item_id, enrollment_id, section_id')
      .in('enrollment_id', [...studentByEnrollment.keys()])
    if (itemError) return { kind: 'error' }
    const items = itemRows ?? []
    if (items.length === 0) return { kind: 'ready', term, items: [], scale }

    const sectionIds = [...new Set(items.map((i) => i.section_id))]
    const studentIds = [...new Set(enrollments.map((e) => e.student_id))]
    const [secRes, gradeRes, profRes, stuRes] = await Promise.all([
      supabase.from('sections').select('section_id, subject_id, section_code').in('section_id', sectionIds),
      supabase.from('grades').select('enrollment_item_id, grade_code').in('enrollment_item_id', items.map((i) => i.enrollment_item_id)),
      supabase.from('profiles').select('profile_id, first_name, last_name').in('profile_id', studentIds),
      supabase.from('students').select('student_id, student_number').in('student_id', studentIds),
    ])
    if (secRes.error || gradeRes.error) return { kind: 'error' }

    const sections = secRes.data ?? []
    const subjectIds = [...new Set(sections.map((s) => s.subject_id))]
    const subRes = subjectIds.length
      ? await supabase.from('subjects').select('subject_id, code, title').in('subject_id', subjectIds)
      : { data: [], error: null }
    if (subRes.error) return { kind: 'error' }

    const subjects = new Map((subRes.data ?? []).map((s) => [s.subject_id, s]))
    const sectionMap = new Map(sections.map((s) => [s.section_id, s]))
    const grades = new Map((gradeRes.data ?? []).map((g) => [g.enrollment_item_id, g.grade_code]))
    // Names and numbers are a convenience: fall back to a label when they cannot be read.
    const names = new Map((profRes.data ?? []).map((p) => [p.profile_id, fullName(p)]))
    const numbers = new Map((stuRes.data ?? []).map((s) => [s.student_id, formatStudentId(s.student_number)]))

    const result: EncodableItem[] = items.map((i) => {
      const sec = sectionMap.get(i.section_id)
      const sub = sec ? subjects.get(sec.subject_id) : undefined
      const studentId = studentByEnrollment.get(i.enrollment_id) ?? ''
      return {
        enrollmentItemId: i.enrollment_item_id,
        studentName: names.get(studentId) ?? 'Student',
        studentNo: numbers.get(studentId) ?? '',
        sectionId: i.section_id,
        subjectCode: sub?.code ?? '-',
        subjectTitle: sub?.title ?? '-',
        sectionCode: sec?.section_code ?? '-',
        gradeCode: grades.get(i.enrollment_item_id) ?? null,
      }
    })
    result.sort(
      (a, b) =>
        a.subjectCode.localeCompare(b.subjectCode) ||
        a.sectionCode.localeCompare(b.sectionCode) ||
        a.studentName.localeCompare(b.studentName)
    )
    return { kind: 'ready', term, items: result, scale }
  } catch {
    return { kind: 'error' }
  }
}
