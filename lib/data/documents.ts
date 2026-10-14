import { createClient } from '@/lib/supabase/server'
import { formatStudentId } from '@/lib/auth/student-id'

// Server-side reads for document requests. Every query runs with the signed-in user's own session
// (anon key + auth cookies), so Row Level Security does the isolation: a student sees only their own
// requests, the Registrar sees all. No server-only key is used here. Import from Server Components and
// Server Actions only.

export type DocumentStatus = 'Pending' | 'Processing' | 'Ready' | 'Released' | 'Rejected'

export const DOCUMENT_STATUSES: readonly DocumentStatus[] = ['Pending', 'Processing', 'Ready', 'Released', 'Rejected']

// The only legal next steps, one at a time (the database trigger enforces the same flow).
export const NEXT_STATUSES: Record<DocumentStatus, readonly DocumentStatus[]> = {
  Pending: ['Processing', 'Rejected'],
  Processing: ['Ready', 'Rejected'],
  Ready: ['Released'],
  Released: [],
  Rejected: [],
}

export type DocumentTypeOption = { id: number; name: string }

export type DocumentRequest = {
  id: number
  ticketNumber: string
  typeName: string
  purpose: string
  copies: number
  status: DocumentStatus
  requestedAt: string
  processedAt: string | null
  remarks: string | null
}

export type StudentDocumentsState =
  | { kind: 'ready'; types: DocumentTypeOption[]; requests: DocumentRequest[] }
  | { kind: 'error' }

export type RegistrarDocumentRequest = DocumentRequest & {
  studentName: string
  studentNo: string
  /** Name of the Registrar staff member who last processed it (null when unknown or untouched). */
  processedByName: string | null
}

export type RegistrarDocumentsState = { kind: 'ready'; requests: RegistrarDocumentRequest[] } | { kind: 'error' }

const toStatus = (s: string): DocumentStatus =>
  (DOCUMENT_STATUSES as readonly string[]).includes(s) ? (s as DocumentStatus) : 'Pending'

export async function getDocumentTypes(): Promise<DocumentTypeOption[]> {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('document_types')
    .select('document_type_id, name')
    .order('name', { ascending: true })
  if (error) throw error
  return (data ?? []).map((t) => ({ id: t.document_type_id, name: t.name }))
}

// The signed-in student's document types (for the dropdown) and own requests, newest first. Never
// throws: failures come back as { kind: 'error' }.
export async function getStudentDocumentsState(): Promise<StudentDocumentsState> {
  try {
    const supabase = await createClient()
    const { data: userData } = await supabase.auth.getUser()
    const user = userData.user
    if (!user) return { kind: 'error' }

    const [types, reqRes] = await Promise.all([
      getDocumentTypes(),
      supabase
        .from('document_requests')
        .select('request_id, ticket_number, document_type_id, purpose, copies, status, requested_at, processed_at, remarks')
        .eq('student_id', user.id)
        .order('requested_at', { ascending: false })
        .order('request_id', { ascending: false }),
    ])
    if (reqRes.error) return { kind: 'error' }

    const typeNames = new Map(types.map((t) => [t.id, t.name]))
    const requests: DocumentRequest[] = (reqRes.data ?? []).map((r) => ({
      id: r.request_id,
      ticketNumber: r.ticket_number,
      typeName: typeNames.get(r.document_type_id) ?? 'Document',
      purpose: r.purpose,
      copies: r.copies,
      status: toStatus(r.status),
      requestedAt: r.requested_at,
      processedAt: r.processed_at,
      remarks: r.remarks,
    }))
    return { kind: 'ready', types, requests }
  } catch {
    return { kind: 'error' }
  }
}

// Every document request (Registrar only: RLS returns nothing to other roles), oldest first so the
// longest-waiting request is on top. Student names and processor names are a convenience: when they
// cannot be read, a plain label is shown. Never throws.
export async function getRegistrarDocumentsState(): Promise<RegistrarDocumentsState> {
  try {
    const supabase = await createClient()
    const [types, reqRes] = await Promise.all([
      getDocumentTypes(),
      supabase
        .from('document_requests')
        .select(
          'request_id, ticket_number, student_id, document_type_id, purpose, copies, status, requested_at, processed_by, processed_at, remarks'
        )
        .order('requested_at', { ascending: true })
        .order('request_id', { ascending: true }),
    ])
    if (reqRes.error) return { kind: 'error' }

    const rows = reqRes.data ?? []
    const personIds = [...new Set(rows.flatMap((r) => [r.student_id, r.processed_by]).filter((v): v is string => v !== null))]
    const studentIds = [...new Set(rows.map((r) => r.student_id))]
    const [profRes, stuRes] = await Promise.all([
      personIds.length
        ? supabase.from('profiles').select('profile_id, first_name, last_name').in('profile_id', personIds)
        : Promise.resolve({ data: [], error: null }),
      studentIds.length
        ? supabase.from('students').select('student_id, student_number').in('student_id', studentIds)
        : Promise.resolve({ data: [], error: null }),
    ])
    const names = new Map((profRes.data ?? []).map((p) => [p.profile_id, `${p.last_name}, ${p.first_name}`]))
    const numbers = new Map((stuRes.data ?? []).map((s) => [s.student_id, formatStudentId(s.student_number)]))
    const typeNames = new Map(types.map((t) => [t.id, t.name]))

    const requests: RegistrarDocumentRequest[] = rows.map((r) => ({
      id: r.request_id,
      ticketNumber: r.ticket_number,
      typeName: typeNames.get(r.document_type_id) ?? 'Document',
      purpose: r.purpose,
      copies: r.copies,
      status: toStatus(r.status),
      requestedAt: r.requested_at,
      processedAt: r.processed_at,
      remarks: r.remarks,
      studentName: names.get(r.student_id) ?? 'Student',
      studentNo: numbers.get(r.student_id) ?? '',
      processedByName: r.processed_by ? (names.get(r.processed_by) ?? null) : null,
    }))
    return { kind: 'ready', requests }
  } catch {
    return { kind: 'error' }
  }
}
