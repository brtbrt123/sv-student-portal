import { describe, expect, it } from 'vitest'
import { countByStatus, firstWhere, queueCounts, roleCounts, userTotals } from '@/lib/data/dashboards-map'

describe('dashboard helpers (UT-110..119)', () => {
  it('UT-110 countByStatus counts each listed status and starts at zero', () => {
    expect(countByStatus([{ status: 'Pending' }, { status: 'Pending' }, { status: 'Ready' }], ['Pending', 'Processing', 'Ready'] as const)).toEqual({
      Pending: 2,
      Processing: 0,
      Ready: 1,
    })
  })
  it('UT-111 countByStatus ignores statuses that are not listed', () => {
    expect(countByStatus([{ status: 'Released' }], ['Pending'] as const)).toEqual({ Pending: 0 })
  })
  it('UT-112 countByStatus on no rows gives all zeros', () => {
    expect(countByStatus([], ['Pending', 'Ready'] as const)).toEqual({ Pending: 0, Ready: 0 })
  })
  it('UT-113 firstWhere keeps order and stops at n', () => {
    expect(firstWhere([1, 2, 3, 4, 5, 6], (n) => n % 2 === 0, 2)).toEqual([2, 4])
  })
  it('UT-114 firstWhere returns fewer when not enough match', () => {
    expect(firstWhere([1, 3], (n) => n > 2, 5)).toEqual([3])
  })
  it('UT-115 queueCounts counts waiting, serving and held and ignores finished tickets', () => {
    const t = ['Waiting', 'Waiting', 'Serving', 'Held', 'Done', 'No-show', 'Cancelled'].map((status) => ({ status }))
    expect(queueCounts(t)).toEqual({ waiting: 2, serving: 1, held: 1 })
  })
  it('UT-116 roleCounts splits active and inactive per role', () => {
    const roles = [
      { role_id: 1, role_name: 'Admin' },
      { role_id: 2, role_name: 'Student' },
    ]
    const profiles = [
      { role_id: 2, is_active: true },
      { role_id: 2, is_active: false },
      { role_id: 1, is_active: true },
    ]
    expect(roleCounts(profiles, roles)).toEqual([
      { role: 'Admin', users: 1, active: 1, inactive: 0 },
      { role: 'Student', users: 2, active: 1, inactive: 1 },
    ])
  })
  it('UT-117 roleCounts lists a role with no users and skips unknown role ids', () => {
    const rows = roleCounts([{ role_id: 99, is_active: true }], [{ role_id: 1, role_name: 'Admin' }])
    expect(rows).toEqual([{ role: 'Admin', users: 0, active: 0, inactive: 0 }])
  })
  it('UT-118 roleCounts orders by role id', () => {
    const rows = roleCounts(
      [],
      [
        { role_id: 3, role_name: 'C' },
        { role_id: 1, role_name: 'A' },
      ]
    )
    expect(rows.map((r) => r.role)).toEqual(['A', 'C'])
  })
  it('UT-119 userTotals gives total, active and inactive', () => {
    expect(userTotals([{ is_active: true }, { is_active: false }, { is_active: true }])).toEqual({ total: 3, active: 2, inactive: 1 })
    expect(userTotals([])).toEqual({ total: 0, active: 0, inactive: 0 })
  })
})
