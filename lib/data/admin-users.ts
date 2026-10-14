import { createClient } from '@/lib/supabase/server'
import {
  mapAdminUsers,
  mapDepartments,
  type AdminUsersState,
  type RawDepartment,
  type RawProfile,
  type RawProgram,
  type RawStaff,
  type RawStudent,
} from '@/lib/data/admin-users-map'

// Server-side read for the Admin's Users screen (REQ-ADM-01). It runs with the signed-in user's own
// session (anon key + auth cookies), so Row Level Security decides what comes back: the Admin can
// read every profile, other roles get nothing useful. No server-only key is used here. The writes
// live in lib/data/admin-users-actions.ts and the types and pure helpers in lib/data/admin-users-map.ts
// (client components import that one, never this file). Import from Server Components only.

// Every account with its role and department or program, plus the lists the forms need. Never
// throws: any failure becomes { kind: 'error' } so the page can say so.
export async function getAdminUsersState(): Promise<AdminUsersState> {
  try {
    const supabase = await createClient()
    const [profRes, staffRes, deptRes, stuRes, progRes, roleRes] = await Promise.all([
      supabase.from('profiles').select('profile_id, first_name, last_name, email, is_active, created_at, roles(role_name)'),
      supabase.from('department_staff').select('profile_id, department_id'),
      supabase.from('departments').select('department_id, name, department_type'),
      supabase.from('students').select('student_id, program_id'),
      supabase.from('programs').select('program_id, code'),
      supabase.from('roles').select('role_id, role_name').order('role_id', { ascending: true }),
    ])
    if (profRes.error || staffRes.error || deptRes.error || stuRes.error || progRes.error || roleRes.error) {
      return { kind: 'error' }
    }
    const departments = (deptRes.data ?? []) as RawDepartment[]
    const users = mapAdminUsers(
      (profRes.data ?? []) as unknown as RawProfile[],
      (staffRes.data ?? []) as RawStaff[],
      departments,
      (stuRes.data ?? []) as RawStudent[],
      (progRes.data ?? []) as RawProgram[]
    )
    const roleNames = ((roleRes.data ?? []) as { role_name: string }[]).map((r) => r.role_name)
    return { kind: 'ready', users, roleNames, departments: mapDepartments(departments) }
  } catch {
    return { kind: 'error' }
  }
}
