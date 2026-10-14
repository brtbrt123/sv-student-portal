import { createClient } from '@/lib/supabase/server'
import { getCurrentTerm, type CurrentTerm } from '@/lib/data/clearance'
import { formatStudentId } from '@/lib/auth/student-id'

// Server-side reads for the Registrar's clearance screen. Every query runs with the signed-in user's
// own session, so Row Level Security decides what is visible. Import from Server Components and
// Server Actions only.

export type RegistrarItem = {
  id: number
  department: string
  status: 'Cleared' | 'Pending'
  clearedAt: string | null
  remarks: string | null
}

export type RegistrarClearance = {
  clearanceId: number
  studentId: string
  studentName: string
  studentNo: string
  requestedAt: string | null
  totalItems: number
  clearedItems: number
  approved: boolean
  approvedAt: string | null
  /** Name of the person who gave final approval (null when unknown or not approved). */
  approvedByName: string | null
  items: RegistrarItem[]
  /** Departments that have not cleared yet. */
  pendingDepartments: string[]
  /** Every office cleared and at least one office exists. */
  ready: boolean
}

export type RegistrarClearanceState =
  | { kind: 'ready'; term: CurrentTerm; clearances: RegistrarClearance[] }
  | { kind: 'no-term' }
  | { kind: 'error' }

const fullName = (p: { first_name: string; last_name: string }) => `${p.last_name}, ${p.first_name}`

// All clearance requests of the current term with their items. Never throws.
export async function getRegistrarClearanceState(): Promise<RegistrarClearanceState> {
  try {
    const supabase = await createClient()
    const term = await getCurrentTerm()
    if (!term) return { kind: 'no-term' }

    const [clearRes, itemsRes] = await Promise.all([
      supabase
        .from('v_clearances')
        .select('clearance_id, student_id, term_id, created_at, approved_by, approved_at, total_items, cleared_items, status')
        .eq('term_id', term.termId)
        .order('created_at', { ascending: true }),
      supabase
        .from('v_clearance_items')
        .select('clearance_item_id, clearance_id, department_name, department_type, cleared_at, remarks, status')
        .eq('term_id', term.termId),
    ])
    if (clearRes.error || itemsRes.error) return { kind: 'error' }

    const rows = clearRes.data ?? []
    const personIds = [
      ...new Set(rows.flatMap((r) => [r.student_id, r.approved_by]).filter((v): v is string => v !== null)),
    ]
    const studentIds = [...new Set(rows.map((r) => r.student_id).filter((v): v is string => v !== null))]

    // Names and student numbers are a convenience: if the Registrar cannot read them, fall back to a label.
    const [profRes, stuRes] = await Promise.all([
      personIds.length
        ? supabase.from('profiles').select('profile_id, first_name, last_name').in('profile_id', personIds)
        : Promise.resolve({ data: [], error: null }),
      studentIds.length
        ? supabase.from('students').select('student_id, student_number').in('student_id', studentIds)
        : Promise.resolve({ data: [], error: null }),
    ])
    const names = new Map((profRes.data ?? []).map((p) => [p.profile_id, fullName(p)]))
    const numbers = new Map((stuRes.data ?? []).map((s) => [s.student_id, formatStudentId(s.student_number)]))

    const itemsByClearance = new Map<number, RegistrarItem[]>()
    for (const i of itemsRes.data ?? []) {
      if (i.clearance_id === null || i.clearance_item_id === null) continue
      const list = itemsByClearance.get(i.clearance_id) ?? []
      list.push({
        id: i.clearance_item_id,
        department: i.department_name ?? 'Department',
        status: i.status === 'Cleared' ? 'Cleared' : 'Pending',
        clearedAt: i.cleared_at,
        remarks: i.remarks,
      })
      itemsByClearance.set(i.clearance_id, list)
    }

    const clearances: RegistrarClearance[] = []
    for (const r of rows) {
      if (r.clearance_id === null || r.student_id === null) continue
      const items = (itemsByClearance.get(r.clearance_id) ?? []).sort((a, b) => a.id - b.id)
      const total = r.total_items ?? items.length
      const cleared = r.cleared_items ?? items.filter((i) => i.status === 'Cleared').length
      clearances.push({
        clearanceId: r.clearance_id,
        studentId: r.student_id,
        studentName: names.get(r.student_id) ?? 'Student',
        studentNo: numbers.get(r.student_id) ?? '',
        requestedAt: r.created_at,
        totalItems: total,
        clearedItems: cleared,
        approved: r.approved_at !== null,
        approvedAt: r.approved_at,
        approvedByName: r.approved_by ? (names.get(r.approved_by) ?? null) : null,
        items,
        pendingDepartments: items.filter((i) => i.status !== 'Cleared').map((i) => i.department),
        ready: total > 0 && cleared === total,
      })
    }
    return { kind: 'ready', term, clearances }
  } catch {
    return { kind: 'error' }
  }
}
