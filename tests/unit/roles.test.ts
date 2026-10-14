import { describe, expect, it } from 'vitest'
import { ROLE_HOME, ROLES, isPublicPath, isRoleName, roleForPath } from '@/lib/auth/roles'

describe('role routing (UT-17..20)', () => {
  it('UT-17 isRoleName accepts the five roles only, with the exact spelling', () => {
    for (const role of ROLES) expect(isRoleName(role)).toBe(true)
    expect(isRoleName('admin')).toBe(false)
    expect(isRoleName('Teacher')).toBe(false)
    expect(isRoleName(5)).toBe(false)
    expect(isRoleName(null)).toBe(false)
  })
  it('UT-18 each role lands on its own module', () => {
    expect(ROLE_HOME).toEqual({
      Student: '/student',
      Registrar: '/registrar',
      Cashier: '/cashier',
      Department: '/department',
      Admin: '/admin',
    })
  })
  it('UT-19 roleForPath maps a URL to the module it belongs to', () => {
    expect(roleForPath('/student')).toBe('Student')
    expect(roleForPath('/cashier/payments')).toBe('Cashier')
    expect(roleForPath('/admin/audit-log')).toBe('Admin')
  })
  it('UT-20 roleForPath does not match look-alike paths or pages outside the modules', () => {
    expect(roleForPath('/studentx')).toBeNull()
    expect(roleForPath('/login')).toBeNull()
    expect(roleForPath('/')).toBeNull()
  })
})

describe('public paths (UT-21..22)', () => {
  it('UT-21 the enrollment site and the set-password link are public, including sub-pages', () => {
    expect(isPublicPath('/apply')).toBe(true)
    expect(isPublicPath('/apply/enroll')).toBe(true)
    expect(isPublicPath('/auth/confirm')).toBe(true)
  })
  it('UT-22 module pages and look-alikes are not public', () => {
    expect(isPublicPath('/student')).toBe(false)
    expect(isPublicPath('/applyx')).toBe(false)
    expect(isPublicPath('/registrar/applications')).toBe(false)
  })
})
