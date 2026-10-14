import { createClient } from '@/lib/supabase/server'

// Server-side reads for the queue (ticket numbers). Everything runs with the signed-in user's own session
// and goes through the database functions of docs/database/queue_rules.sql: a student gets only their own
// ticket and the numbers (never another student's name); the Registrar gets today's whole list. The
// functions are not in types/database.types.ts, so the calls go through a local cast (same as
// app/apply/programs.ts). Import from Server Components and Server Actions only.

export type QueueService = 'Enrollment' | 'Documents'
export const QUEUE_SERVICES: readonly QueueService[] = ['Enrollment', 'Documents']
export const isQueueService = (value: unknown): value is QueueService =>
  typeof value === 'string' && (QUEUE_SERVICES as readonly string[]).includes(value)

export type TicketStatus = 'Waiting' | 'Serving' | 'Done' | 'No-show' | 'Cancelled'
const TICKET_STATUSES: readonly TicketStatus[] = ['Waiting', 'Serving', 'Done', 'No-show', 'Cancelled']
const toStatus = (s: unknown): TicketStatus | null => (TICKET_STATUSES as readonly unknown[]).includes(s) ? (s as TicketStatus) : null

export type RpcResult<T> = PromiseLike<{ data: T | null; error: { code?: string; message?: string; details?: string | null } | null }>
export type Rpc = <T>(fn: string, args?: Record<string, unknown>) => RpcResult<T>

/** The Supabase rpc caller of the signed-in user, typed loosely because the functions are not in the generated types. */
export async function queueRpc(): Promise<Rpc> {
  const supabase = await createClient()
  return supabase.rpc.bind(supabase) as unknown as Rpc
}

export type MyQueueStatus = {
  isOpen: boolean
  hasTicket: boolean
  ticketLabel: string | null
  ticketStatus: TicketStatus | null
  /** Tickets waiting with a lower number than mine (0 when I have none). */
  peopleAhead: number
  nowServing: string | null
  waitingTotal: number
  /** Average time at the window of today's finished tickets, in seconds; null until one is done. */
  avgServiceSeconds: number | null
  /** The window to go to, only while my ticket is being served. */
  windowLabel: string | null
}

type MyStatusRow = {
  is_open: boolean | null
  has_ticket: boolean | null
  ticket_label: string | null
  ticket_status: string | null
  people_ahead: number | null
  now_serving: string | null
  waiting_total: number | null
  avg_service_seconds: number | null
  window_label: string | null
}

// The signed-in student's place in a queue. Null when the call fails (the screen then shows a plain
// "could not load" note), never throws.
export async function getMyQueueStatus(service: QueueService): Promise<MyQueueStatus | null> {
  try {
    const rpc = await queueRpc()
    const { data, error } = await rpc<MyStatusRow[]>('queue_my_status', { p_service: service })
    if (error || !Array.isArray(data) || data.length === 0) return null
    const r = data[0]
    return {
      isOpen: r.is_open !== false,
      hasTicket: r.has_ticket === true,
      ticketLabel: r.ticket_label,
      ticketStatus: toStatus(r.ticket_status),
      peopleAhead: r.people_ahead ?? 0,
      nowServing: r.now_serving,
      waitingTotal: r.waiting_total ?? 0,
      avgServiceSeconds: r.avg_service_seconds,
      windowLabel: r.window_label,
    }
  } catch {
    return null
  }
}

export type StaffTicket = {
  ticketId: number
  label: string
  number: number
  status: TicketStatus
  studentNumber: string
  studentName: string
  windowLabel: string | null
  createdAt: string
  calledAt: string | null
  finishedAt: string | null
}

type StaffRow = {
  ticket_id: number
  ticket_label: string
  ticket_number: number
  status: string
  student_number: string | null
  student_name: string | null
  window_label: string | null
  created_at: string
  called_at: string | null
  finished_at: string | null
}

// Today's tickets of a service for the Registrar, in ticket order. Null when the call fails.
export async function getStaffQueue(service: QueueService): Promise<StaffTicket[] | null> {
  try {
    const rpc = await queueRpc()
    const { data, error } = await rpc<StaffRow[]>('queue_staff_list', { p_service: service })
    if (error || !Array.isArray(data)) return null
    return data.flatMap((r) => {
      const status = toStatus(r.status)
      if (!status) return []
      return [
        {
          ticketId: Number(r.ticket_id),
          label: r.ticket_label,
          number: r.ticket_number,
          status,
          studentNumber: r.student_number ?? '',
          studentName: r.student_name ?? '',
          windowLabel: r.window_label,
          createdAt: r.created_at,
          calledAt: r.called_at,
          finishedAt: r.finished_at,
        },
      ]
    })
  } catch {
    return null
  }
}

export type QueueStudentCard = {
  studentId: string
  studentNumber: string
  studentName: string
  programCode: string
  programName: string
  /** The label of the student's active enrollment ticket today, if they already have one. */
  alreadyQueuedLabel: string | null
}

type CardRow = {
  student_id: string
  student_number: string | null
  student_name: string | null
  program_code: string | null
  program_name: string | null
  already_queued_label: string | null
}

// One student's card for the Registrar's scan screen (name, number, program, an existing ticket). The
// error is returned, not thrown, so the screen can show the database's message.
export async function getQueueStudentCard(
  studentId: string
): Promise<{ card: QueueStudentCard } | { error: { code?: string; message?: string } }> {
  try {
    const rpc = await queueRpc()
    const { data, error } = await rpc<CardRow[]>('queue_student_card', { p_student_id: studentId })
    if (error) return { error }
    const r = Array.isArray(data) ? data[0] : null
    if (!r) return { error: {} }
    return {
      card: {
        studentId: r.student_id,
        studentNumber: r.student_number ?? '',
        studentName: r.student_name ?? '',
        programCode: r.program_code ?? '',
        programName: r.program_name ?? '',
        alreadyQueuedLabel: r.already_queued_label,
      },
    }
  } catch {
    return { error: {} }
  }
}
