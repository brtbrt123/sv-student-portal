// Types and pure helpers for the Admin's Users screen. This file imports NOTHING from the server (no Supabase,
// no next/headers), so the client component and the tests can import it. The reader that talks to the
// database is lib/data/admin-users.ts.
// Server-side read for the Admin's Users screen (REQ-ADM-01). It runs with the signed-in user's own
// session (anon key + auth cookies), so Row Level Security decides what comes back: the Admin can
// read every profile, other roles get nothing useful. No server-only key is used here. The writes
// live in lib/data/admin-users-actions.ts. Import from Server Components only.

export type AdminUserRow = {
  id: string
  firstName: string
  lastName: string
  name: string
  email: string
  role: string
  /** Department name (Department, Cashier), program code (Student) or 'None'. */
  department: string
  /** department_id of a Department or Cashier user, for the edit form; null otherwise. */
  departmentId: number | null
  active: boolean
  /** "Aug 1, 2026" */
  created: string
}

export type AdminDepartment = { id: number; name: string; type: string }

export type AdminUsersState =
  | { kind: 'ready'; users: AdminUserRow[]; roleNames: string[]; departments: AdminDepartment[] }
  | { kind: 'error' }

export type RawProfile = {
  profile_id: string
  first_name: string | null
  last_name: string | null
  email: string | null
  is_active: boolean | null
  created_at: string | null
  roles: { role_name: string } | { role_name: string }[] | null
}
export type RawStaff = { profile_id: string; department_id: number }
export type RawDepartment = { department_id: number; name: string; department_type: string }
export type RawStudent = { student_id: string; program_id: number }
export type RawProgram = { program_id: number; code: string }

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

/** "2026-08-01T14:05:00+00:00" to "Aug 1, 2026" (the date as written in the data). */
export function formatCreated(iso: string | null): string {
  if (!iso) return '-'
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso)
  if (!m) return '-'
  const month = MONTHS[Number(m[2]) - 1]
  return month ? `${month} ${Number(m[3])}, ${m[1]}` : '-'
}

/** Raw rows to display rows, oldest account first, ties by email. Pure: no database access. */
export function mapAdminUsers(
  profiles: RawProfile[],
  staff: RawStaff[],
  departments: RawDepartment[],
  students: RawStudent[],
  programs: RawProgram[]
): AdminUserRow[] {
  const staffDept = new Map(staff.map((s) => [s.profile_id, s.department_id]))
  const deptName = new Map(departments.map((d) => [d.department_id, d.name]))
  const studentProgram = new Map(students.map((s) => [s.student_id, s.program_id]))
  const programCode = new Map(programs.map((p) => [p.program_id, p.code]))

  const rows = profiles.map((p): AdminUserRow => {
    const roleRel = Array.isArray(p.roles) ? p.roles[0] : p.roles
    const departmentId = staffDept.get(p.profile_id) ?? null
    const programId = studentProgram.get(p.profile_id)
    const department =
      departmentId !== null
        ? (deptName.get(departmentId) ?? 'None')
        : programId !== undefined
          ? (programCode.get(programId) ?? 'None')
          : 'None'
    const firstName = (p.first_name ?? '').trim()
    const lastName = (p.last_name ?? '').trim()
    return {
      id: p.profile_id,
      firstName,
      lastName,
      name: `${firstName} ${lastName}`.trim() || 'Unnamed',
      email: p.email ?? '',
      role: roleRel?.role_name ?? 'Unknown',
      department,
      departmentId,
      active: p.is_active === true,
      created: formatCreated(p.created_at),
    }
  })

  const createdAt = new Map(profiles.map((p) => [p.profile_id, p.created_at ?? '']))
  return rows.sort(
    (a, b) =>
      (createdAt.get(a.id) ?? '').localeCompare(createdAt.get(b.id) ?? '') || a.email.localeCompare(b.email)
  )
}

/** Departments for the staff form, by name. Pure. */
export function mapDepartments(rows: RawDepartment[]): AdminDepartment[] {
  return rows
    .map((d) => ({ id: d.department_id, name: d.name, type: d.department_type }))
    .sort((a, b) => a.name.localeCompare(b.name))
}

/** The department type a role needs: Department = Academic, Cashier = Financial, others none. */
export function departmentTypeFor(role: string): 'Academic' | 'Financial' | null {
  if (role === 'Department') return 'Academic'
  if (role === 'Cashier') return 'Financial'
  return null
}

