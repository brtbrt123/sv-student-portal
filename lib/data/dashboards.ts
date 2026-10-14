import { createClient } from '@/lib/supabase/server'
import { getApplicationsState } from '@/lib/data/applications'
import { getEnrollmentsReviewState, type EnrollmentReviewItem } from '@/lib/data/enrollments-review'
import { getRegistrarDocumentsState, type RegistrarDocumentRequest } from '@/lib/data/documents'
import { getStaffQueue, type QueueService } from '@/lib/data/queue'
import { getAuditLogState, type AuditEntry } from '@/lib/data/audit'
import { countByStatus, firstWhere, queueCounts, roleCounts, userTotals, type QueueCounts, type RoleCountRow, type UserTotals } from '@/lib/data/dashboards-map'

// Server-side reads for the Registrar and Admin dashboards. Everything runs with the signed-in user's
// own session, so Row Level Security decides what is visible. Existing readers are reused; only the
// counts they do not give are added here. Each block fails on its own: it is { kind: 'error' } and the
// rest of the dashboard still loads. Nothing here throws. Import from Server Components only.

export type Block<T> = ({ kind: 'ready' } & T) | { kind: 'error' }

export const DASHBOARD_PREVIEW_ROWS = 5
export const ADMIN_RECENT_AUDIT = 5

export type RegistrarDashboard = {
  applications: Block<{ pending: number }>
  enrollments: Block<{ pending: number; rows: EnrollmentReviewItem[] }>
  documents: Block<{ pending: number; processing: number; ready: number; rows: RegistrarDocumentRequest[] }>
  queue: Block<{ enrollment: QueueCounts; documents: QueueCounts }>
}

async function safe<T>(read: () => Promise<Block<T>>): Promise<Block<T>> {
  try {
    return await read()
  } catch {
    return { kind: 'error' }
  }
}

export async function getRegistrarDashboard(): Promise<RegistrarDashboard> {
  const [applications, enrollments, documents, queue] = await Promise.all([
    safe<{ pending: number }>(async () => {
      const s = await getApplicationsState()
      if (s.kind === 'error') return { kind: 'error' }
      return { kind: 'ready', pending: s.applications.filter((a) => a.status === 'Pending').length }
    }),
    safe<{ pending: number; rows: EnrollmentReviewItem[] }>(async () => {
      const s = await getEnrollmentsReviewState()
      if (s.kind === 'error') return { kind: 'error' }
      const pending = s.enrollments.filter((e) => e.status === 'Pending')
      return { kind: 'ready', pending: pending.length, rows: pending.slice(0, DASHBOARD_PREVIEW_ROWS) }
    }),
    safe<{ pending: number; processing: number; ready: number; rows: RegistrarDocumentRequest[] }>(async () => {
      const s = await getRegistrarDocumentsState()
      if (s.kind === 'error') return { kind: 'error' }
      const c = countByStatus(s.requests, ['Pending', 'Processing', 'Ready'] as const)
      const rows = firstWhere(s.requests, (r) => r.status === 'Pending' || r.status === 'Processing', DASHBOARD_PREVIEW_ROWS)
      return { kind: 'ready', pending: c.Pending, processing: c.Processing, ready: c.Ready, rows }
    }),
    safe<{ enrollment: QueueCounts; documents: QueueCounts }>(async () => {
      const services: QueueService[] = ['Enrollment', 'Documents']
      const [e, d] = await Promise.all(services.map((s) => getStaffQueue(s)))
      if (!e || !d) return { kind: 'error' }
      return { kind: 'ready', enrollment: queueCounts(e), documents: queueCounts(d) }
    }),
  ])
  return { applications, enrollments, documents, queue }
}

export type AdminDashboard = {
  users: Block<{ totals: UserTotals; byRole: RoleCountRow[] }>
  audit: Block<{ recent: AuditEntry[]; total: number }>
}

export async function getAdminDashboard(): Promise<AdminDashboard> {
  const [users, audit] = await Promise.all([
    safe<{ totals: UserTotals; byRole: RoleCountRow[] }>(async () => {
      const supabase = await createClient()
      const [pRes, rRes] = await Promise.all([
        supabase.from('profiles').select('role_id, is_active'),
        supabase.from('roles').select('role_id, role_name'),
      ])
      if (pRes.error || rRes.error) return { kind: 'error' }
      const profiles = pRes.data ?? []
      return { kind: 'ready', totals: userTotals(profiles), byRole: roleCounts(profiles, rRes.data ?? []) }
    }),
    safe<{ recent: AuditEntry[]; total: number }>(async () => {
      const s = await getAuditLogState()
      if (s.kind === 'error') return { kind: 'error' }
      return { kind: 'ready', recent: s.entries.slice(0, ADMIN_RECENT_AUDIT), total: s.total }
    }),
  ])
  return { users, audit }
}
