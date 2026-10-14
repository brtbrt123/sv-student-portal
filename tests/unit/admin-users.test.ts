import { describe, expect, it } from 'vitest'
import { departmentTypeFor, formatCreated, mapAdminUsers, mapDepartments } from '@/lib/data/admin-users-map'

const profile = (id: string, role: string | null, extra: Record<string, unknown> = {}) => ({
  profile_id: id,
  first_name: 'Ana',
  last_name: 'Cruz',
  email: `${id}@example.com`,
  is_active: true,
  created_at: '2026-08-01T14:05:00+00:00',
  roles: role ? { role_name: role } : null,
  ...extra,
})

describe('Admin users screen mapping (UT-94..99)', () => {
  it('UT-94 a created date shows as "Aug 1, 2026" and a missing or bad one as a dash', () => {
    expect(formatCreated('2026-08-01T14:05:00+00:00')).toBe('Aug 1, 2026')
    expect(formatCreated('2026-12-25')).toBe('Dec 25, 2026')
    expect(formatCreated(null)).toBe('-')
    expect(formatCreated('not a date')).toBe('-')
    expect(formatCreated('2026-13-01')).toBe('-')
  })

  it('UT-95 a Department user shows their department name and keeps the department id for the edit form', () => {
    const rows = mapAdminUsers(
      [profile('d1', 'Department')],
      [{ profile_id: 'd1', department_id: 7 }],
      [{ department_id: 7, name: 'Computer Studies', department_type: 'Academic' }],
      [],
      []
    )
    expect(rows[0].department).toBe('Computer Studies')
    expect(rows[0].departmentId).toBe(7)
    expect(rows[0].role).toBe('Department')
    expect(rows[0].name).toBe('Ana Cruz')
  })

  it('UT-96 a Student shows their program code and has no department id', () => {
    const rows = mapAdminUsers([profile('s1', 'Student')], [], [], [{ student_id: 's1', program_id: 3 }], [{ program_id: 3, code: 'BSIT' }])
    expect(rows[0].department).toBe('BSIT')
    expect(rows[0].departmentId).toBeNull()
  })

  it('UT-97 an account with no department or program shows None; a missing role shows Unknown; missing names show Unnamed', () => {
    const rows = mapAdminUsers([profile('a1', null, { first_name: null, last_name: ' ' })], [], [], [], [])
    expect(rows[0].department).toBe('None')
    expect(rows[0].role).toBe('Unknown')
    expect(rows[0].name).toBe('Unnamed')
  })

  it('UT-98 the role may arrive as an array, is_active only counts when true, and rows are oldest first', () => {
    const rows = mapAdminUsers(
      [
        profile('b', 'Admin', { created_at: '2026-09-01T00:00:00+00:00', roles: [{ role_name: 'Admin' }] }),
        profile('a', 'Registrar', { is_active: null }),
      ],
      [],
      [],
      [],
      []
    )
    expect(rows.map((r) => r.id)).toEqual(['a', 'b'])
    expect(rows[0].active).toBe(false)
    expect(rows[1].role).toBe('Admin')
  })

  it('UT-99 the department list is sorted by name, and each role needs the right department type', () => {
    const list = mapDepartments([
      { department_id: 2, name: 'Registrar Office', department_type: 'Administrative' },
      { department_id: 1, name: 'Accounting', department_type: 'Financial' },
    ])
    expect(list.map((d) => d.name)).toEqual(['Accounting', 'Registrar Office'])
    expect(list[0]).toEqual({ id: 1, name: 'Accounting', type: 'Financial' })
    expect(departmentTypeFor('Department')).toBe('Academic')
    expect(departmentTypeFor('Cashier')).toBe('Financial')
    expect(departmentTypeFor('Registrar')).toBeNull()
    expect(departmentTypeFor('Admin')).toBeNull()
    expect(departmentTypeFor('Student')).toBeNull()
  })
})
