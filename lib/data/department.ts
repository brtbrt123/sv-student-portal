import { createClient } from '@/lib/supabase/server'
import { getCurrentTerm, type CurrentTerm } from '@/lib/data/clearance'
import { formatStudentId } from '@/lib/auth/student-id'

// Server-side reads for the signed-in Department user. Every query runs with the user's own session
// (anon key + auth cookies), so Row Level Security does the isolation: a Department user only receives
// the clearance items and holds of their own department. No server-only key is used here.
// Import this file from Server Components and Server Actions only.

export type DepartmentInfo = { id: number; name: string; code: string }

export type ActiveHoldNote = { holdId: number; reason: string; placedByName: string }

export type ReviewItem = {
  itemId: number
  studentId: string
  studentNo: string
  name: string
  program: string
  /** "Oct 3, 2026": when the student requested clearance. */
  requestedOn: string
  status: 'Pending' | 'Cleared'
  clearedOn: string | null
  remarks: string | null
  /** Active holds from this department on this student (they block approval). */
  holds: ActiveHoldNote[]
}

export type HoldRow = {
  holdId: number
  studentId: string
  studentNo: string
  name: string
  reason: string
  placedByName: string
  placedOn: string
  status: 'Active' | 'Lifted'
  liftedOn: string | null
  liftedByName: string | null
}

export type PickerStudent = { studentId: string; studentNo: string; name: string; program: string }

export type DepartmentState =
  | {
      kind: 'ready'
      department: DepartmentInfo
      term: CurrentTerm | null
      items: ReviewItem[]
      holds: HoldRow[]
      /** Students this department may place a hold on (programs of the department). */
      students: PickerStudent[]
    }
  | { kind: 'no-department' }
  | { kind: 'error' }

// Philippine time on the server and in the browser, so the text is identical (no hydration mismatch).
const SHORT = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'Asia/Manila' })

function formatDate(iso: string | null | undefined): string {
  if (!iso) return '-'
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? '-' : SHORT.format(d)
}

// The signed-in Department user's own department (department_staff is readable for the own row only).
export async function getMyDepartment(): Promise<{ userId: string; department: DepartmentInfo } | null> {
  const supabase = await createClient()
  const { data: userData } = await supabase.auth.getUser()
  const user = userData.user
  if (!user) return null
  const { data: staff, error } = await supabase
    .from('department_staff')
    .select('department_id')
    .eq('profile_id', user.id)
    .maybeSingle()
  if (error) throw error
  if (!staff) return null
  const { data: dept, error: deptError } = await supabase
    .from('departments')
    .select('department_id, code, name')
    .eq('department_id', staff.department_id)
    .maybeSingle()
  if (deptError) throw deptError
  if (!dept) return null
  return { userId: user.id, department: { id: dept.department_id, name: dept.name, code: dept.code } }
}

// Everything the three Department screens need, in one pass. Never throws: failures come back as
// { kind: 'error' } so the page can show a calm message without internals.
export async function getDepartmentState(): Promise<DepartmentState> {
  try {
    const mine = await getMyDepartment()
    if (!mine) return { kind: 'no-department' }
    const { userId, department } = mine
    const supabase = await createClient()
    const term = await getCurrentTerm()

    const [itemsRes, holdsRes, studentsRes, programsRes] = await Promise.all([
      term
        ? supabase
            .from('v_clearance_items')
            .select('clearance_item_id, clearance_id, student_id, term_id, department_id, cleared_at, remarks, status')
            .eq('term_id', term.termId)
            .eq('department_id', department.id)
            .order('clearance_item_id')
        : Promise.resolve({ data: [], error: null }),
      supabase
        .from('academic_holds')
        .select('hold_id, student_id, department_id, reason, placed_by, placed_at, lifted_by, lifted_at')
        .eq('department_id', department.id)
        .order('placed_at', { ascending: false }),
      supabase.from('students').select('student_id, student_number, program_id'),
      supabase.from('programs').select('program_id, department_id, code'),
    ])
    if (itemsRes.error || holdsRes.error || studentsRes.error || programsRes.error) return { kind: 'error' }

    const items = itemsRes.data ?? []
    const holds = holdsRes.data ?? []
    const programs = new Map((programsRes.data ?? []).map((p) => [p.program_id, p]))
    const studentRows = new Map((studentsRes.data ?? []).map((s) => [s.student_id, s]))

    // Requested date comes from the student's clearance.
    const clearanceIds = [...new Set(items.flatMap((i) => (i.clearance_id === null ? [] : [i.clearance_id])))]
    const created = new Map<number, string | null>()
    if (clearanceIds.length > 0) {
      const { data, error } = await supabase
        .from('v_clearances')
        .select('clearance_id, created_at')
        .in('clearance_id', clearanceIds)
      if (error) return { kind: 'error' }
      for (const c of data ?? []) if (c.clearance_id !== null) created.set(c.clearance_id, c.created_at)
    }

    // Names: profiles are readable for the own row and for students that have an item with this
    // department. Anyone else falls back to a neutral label (never an id).
    const profileIds = [
      ...new Set([
        ...items.flatMap((i) => (i.student_id ? [i.student_id] : [])),
        ...holds.flatMap((h) => [h.student_id, h.placed_by, ...(h.lifted_by ? [h.lifted_by] : [])]),
        ...studentRows.keys(),
      ]),
    ]
    const names = new Map<string, string>()
    if (profileIds.length > 0) {
      const { data, error } = await supabase
        .from('profiles')
        .select('profile_id, first_name, last_name')
        .in('profile_id', profileIds)
      if (error) return { kind: 'error' }
      for (const p of data ?? []) names.set(p.profile_id, `${p.last_name}, ${p.first_name}`)
    }
    const studentName = (id: string) => names.get(id) ?? (formatStudentId(studentRows.get(id)?.student_number) || 'Student')
    const staffName = (id: string) =>
      id === userId ? `${names.get(id) ?? 'You'} (you)` : (names.get(id) ?? 'Department staff')
    const studentNo = (id: string) => formatStudentId(studentRows.get(id)?.student_number) || '-'
    const programCode = (id: string) => {
      const s = studentRows.get(id)
      return s ? (programs.get(s.program_id)?.code ?? '-') : '-'
    }

    const activeByStudent = new Map<string, ActiveHoldNote[]>()
    for (const h of holds) {
      if (h.lifted_at !== null) continue
      const list = activeByStudent.get(h.student_id) ?? []
      list.push({ holdId: h.hold_id, reason: h.reason, placedByName: staffName(h.placed_by) })
      activeByStudent.set(h.student_id, list)
    }

    const reviewItems: ReviewItem[] = items.flatMap((i) => {
      if (i.clearance_item_id === null || i.student_id === null) return []
      return [
        {
          itemId: i.clearance_item_id,
          studentId: i.student_id,
          studentNo: studentNo(i.student_id),
          name: studentName(i.student_id),
          program: programCode(i.student_id),
          requestedOn: formatDate(i.clearance_id === null ? null : created.get(i.clearance_id)),
          status: i.status === 'Cleared' ? ('Cleared' as const) : ('Pending' as const),
          clearedOn: i.cleared_at ? formatDate(i.cleared_at) : null,
          remarks: i.remarks,
          holds: activeByStudent.get(i.student_id) ?? [],
        },
      ]
    })

    const holdRows: HoldRow[] = holds.map((h) => ({
      holdId: h.hold_id,
      studentId: h.student_id,
      studentNo: studentNo(h.student_id),
      name: studentName(h.student_id),
      reason: h.reason,
      placedByName: staffName(h.placed_by),
      placedOn: formatDate(h.placed_at),
      status: h.lifted_at === null ? 'Active' : 'Lifted',
      liftedOn: h.lifted_at ? formatDate(h.lifted_at) : null,
      liftedByName: h.lifted_by ? staffName(h.lifted_by) : null,
    }))

    // Only students of this department's programs can receive a hold from it.
    const picker: PickerStudent[] = [...studentRows.values()]
      .filter((s) => programs.get(s.program_id)?.department_id === department.id)
      .map((s) => ({
        studentId: s.student_id,
        studentNo: formatStudentId(s.student_number),
        name: names.get(s.student_id) ?? formatStudentId(s.student_number),
        program: programs.get(s.program_id)?.code ?? '-',
      }))
      .sort((a, b) => a.name.localeCompare(b.name))

    return { kind: 'ready', department, term, items: reviewItems, holds: holdRows, students: picker }
  } catch {
    return { kind: 'error' }
  }
}

export type DepartmentCounts = { toReview: number; activeHolds: number; cleared: number; students: number }

export function countDepartment(items: readonly ReviewItem[], holds: readonly HoldRow[]): DepartmentCounts {
  return {
    toReview: items.filter((i) => i.status === 'Pending').length,
    activeHolds: holds.filter((h) => h.status === 'Active').length,
    cleared: items.filter((i) => i.status === 'Cleared').length,
    students: new Set(items.map((i) => i.studentId)).size,
  }
}
