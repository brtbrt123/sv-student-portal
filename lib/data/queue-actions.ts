'use server'

import { revalidatePath } from 'next/cache'
import { getCurrentProfile } from '@/lib/auth/session'
import { NOT_ALLOWED, queueErrorMessage } from '@/lib/data/db-errors'
import { getQueueStudentCard, isQueueService, queueRpc, type QueueService } from '@/lib/data/queue'
import { createQueueToken, verifyQueueToken } from '@/lib/queue/qr-token'
import { getQueueSecret } from '@/lib/queue/qr-secret'
import { formatStudentId } from '@/lib/auth/student-id'

// Server Actions for the queue. They run with the signed-in user's own session: the database functions
// (docs/database/queue_rules.sql) check the role again and are the final gate; the checks here only give
// friendly messages. The only secret used is QUEUE_QR_SECRET, which signs and checks the rotating QR code.

const SESSION_ENDED = 'Your session has ended. Please sign in again.'
const NOT_CONFIGURED = 'The queue is not set up on the server yet. Ask the Admin, then try again.'

// ---- Student: the rotating QR code

export type QueueQrResult = { status: 'ok'; token: string; refreshInSeconds: number } | { status: 'error'; message: string }

// A fresh signed code for the signed-in student. The page asks again when `refreshInSeconds` is over.
export async function getMyQueueQr(): Promise<QueueQrResult> {
  try {
    const profile = await getCurrentProfile()
    if (!profile) return { status: 'error', message: SESSION_ENDED }
    if (profile.role !== 'Student') return { status: 'error', message: NOT_ALLOWED }
    const secret = getQueueSecret()
    if (!secret) return { status: 'error', message: NOT_CONFIGURED }
    const { token, refreshInSeconds } = createQueueToken(profile.id, secret)
    return { status: 'ok', token, refreshInSeconds }
  } catch {
    return { status: 'error', message: 'We could not make your code. Please reload the page.' }
  }
}

// ---- Student: leave the queue

export type QueueActionState = { status: 'idle' | 'success' | 'error'; message: string }

export async function cancelMyTicket(service: QueueService): Promise<QueueActionState> {
  try {
    if (!isQueueService(service)) return { status: 'error', message: 'Unknown queue.' }
    const profile = await getCurrentProfile()
    if (!profile) return { status: 'error', message: SESSION_ENDED }
    const rpc = await queueRpc()
    const { error } = await rpc('queue_cancel_my_ticket', { p_service: service })
    if (error) return { status: 'error', message: queueErrorMessage(error.code, error.message) }
  } catch {
    return { status: 'error', message: queueErrorMessage(undefined, undefined) }
  }
  revalidatePath('/student', 'layout')
  return { status: 'success', message: 'You left the queue.' }
}

// ---- Student: hold my place (bathroom, emergency) and come back

// Hold keeps the ticket's original order but Call next skips it, so the people behind get served. When
// the student is back, the ticket is next. A hold lasts a limited time (the database decides, 15 minutes).
async function changeMyHold(service: QueueService, fn: 'queue_hold_my_ticket' | 'queue_unhold_my_ticket', ok: string): Promise<QueueActionState> {
  try {
    if (!isQueueService(service)) return { status: 'error', message: 'Unknown queue.' }
    const profile = await getCurrentProfile()
    if (!profile) return { status: 'error', message: SESSION_ENDED }
    const rpc = await queueRpc()
    const { error } = await rpc(fn, { p_service: service })
    if (error) return { status: 'error', message: queueErrorMessage(error.code, error.message) }
  } catch {
    return { status: 'error', message: queueErrorMessage(undefined, undefined) }
  }
  revalidatePath('/student', 'layout')
  return { status: 'success', message: ok }
}

export async function holdMyTicket(service: QueueService): Promise<QueueActionState> {
  return changeMyHold(service, 'queue_hold_my_ticket', 'Your place is on hold.')
}

export async function unholdMyTicket(service: QueueService): Promise<QueueActionState> {
  return changeMyHold(service, 'queue_unhold_my_ticket', 'Welcome back. You are next.')
}

// ---- Registrar: the queue desk (one scan = one ticket)

// A scan checks the rotating QR code and issues the ticket in the same step: no Approve button. The student's
// card (name, number, program) comes back with the result so the Registrar can see who was scanned; the
// real identity check (ID against the person) happens at the window, when the ticket is called and the name is
// shown again. A student who already has a ticket in this line is not given a second one: the result says so.
export type DeskState =
  | { status: 'idle'; message: string }
  | { status: 'error'; message: string; stamp: number }
  | {
      status: 'issued'
      message: string
      stamp: number
      label: string
      peopleAhead: number
      studentName: string
      studentNumber: string
      programCode: string
      programName: string
    }
  | {
      status: 'duplicate'
      message: string
      stamp: number
      label: string | null
      studentName: string
      studentNumber: string
      programCode: string
      programName: string
    }

type IssuedRow = { ticket_label: string; people_ahead: number | null }

const TOKEN_MESSAGES = {
  malformed: 'This is not a portal queue code.',
  'bad-signature': 'This is not a valid portal queue code.',
  expired: 'This code has expired. Ask the student to hold the phone up again; the code refreshes every 30 seconds.',
} as const

const deskError = (message: string): DeskState => ({ status: 'error', message, stamp: Date.now() })

export async function queueDeskAction(_prev: DeskState, formData: FormData): Promise<DeskState> {
  void _prev
  const service = formData.get('service')
  if (!isQueueService(service)) return deskError('Choose the queue first.')

  try {
    const profile = await getCurrentProfile()
    if (!profile) return deskError(SESSION_ENDED)
    if (profile.role !== 'Registrar') return deskError(NOT_ALLOWED)

    const token = String(formData.get('token') ?? '').trim()
    if (token === '') return deskError('Scan the student\u2019s code first.')
    const secret = getQueueSecret()
    if (!secret) return deskError(NOT_CONFIGURED)
    const checked = verifyQueueToken(token, secret)
    if (!checked.ok) return deskError(TOKEN_MESSAGES[checked.reason])

    const res = await getQueueStudentCard(checked.studentId)
    if ('error' in res) return deskError(queueErrorMessage(res.error.code, res.error.message))
    const { card } = res
    const who = {
      studentName: card.studentName,
      studentNumber: card.studentNumber,
      programCode: card.programCode,
      programName: card.programName,
    }

    const rpc = await queueRpc()
    const { data, error } = await rpc<IssuedRow[]>('issue_queue_ticket', { p_student_id: card.studentId, p_service: service })
    if (error) {
      if (error.code === 'P0001' && error.message?.startsWith('already queued:')) {
        const label = /#\d{7}/.exec(error.message)?.[0] ?? null
        return {
          status: 'duplicate',
          message: label ? `${card.studentName} already has ticket ${label} in this line.` : `${card.studentName} already has a ticket in this line.`,
          stamp: Date.now(),
          label,
          ...who,
        }
      }
      return deskError(queueErrorMessage(error.code, error.message))
    }
    const row = Array.isArray(data) ? data[0] : null
    if (!row) return deskError(queueErrorMessage(undefined, undefined))

    revalidatePath('/registrar', 'layout')
    return {
      status: 'issued',
      message: `Ticket ${row.ticket_label} issued to ${card.studentName}.`,
      stamp: Date.now(),
      label: row.ticket_label,
      peopleAhead: row.people_ahead ?? 0,
      ...who,
    }
  } catch {
    return deskError(queueErrorMessage(undefined, undefined))
  }
}

// ---- Registrar: call the next ticket, finish the current one

export type CallState =
  | { status: 'idle'; message: string }
  | { status: 'error'; message: string }
  | { status: 'empty'; message: string; stamp: number }
  | { status: 'called'; message: string; label: string; studentName: string; studentNumber: string; stamp: number }

type CalledRow = { ticket_label: string; student_name: string | null; student_number: string | null }

export async function callNextTicket(_prev: CallState, formData: FormData): Promise<CallState> {
  void _prev
  const service = formData.get('service')
  const windowLabel = String(formData.get('window') ?? '').trim().slice(0, 40)
  if (!isQueueService(service)) return { status: 'error', message: 'Choose the queue first.' }

  try {
    const profile = await getCurrentProfile()
    if (!profile) return { status: 'error', message: SESSION_ENDED }
    if (profile.role !== 'Registrar') return { status: 'error', message: NOT_ALLOWED }

    const rpc = await queueRpc()
    const { data, error } = await rpc<CalledRow[]>('queue_call_next', {
      p_service: service,
      p_window: windowLabel === '' ? null : windowLabel,
    })
    if (error) return { status: 'error', message: queueErrorMessage(error.code, error.message) }

    revalidatePath('/registrar', 'layout')
    const row = Array.isArray(data) ? data[0] : null
    if (!row) return { status: 'empty', message: 'Nobody is waiting right now.', stamp: Date.now() }
    return {
      status: 'called',
      message: `Now serving ${row.ticket_label}.`,
      label: row.ticket_label,
      studentName: row.student_name ?? '',
      studentNumber: formatStudentId(row.student_number),
      stamp: Date.now(),
    }
  } catch {
    return { status: 'error', message: queueErrorMessage(undefined, undefined) }
  }
}

export async function finishTicket(_prev: QueueActionState, formData: FormData): Promise<QueueActionState> {
  void _prev
  const idRaw = String(formData.get('ticketId') ?? '')
  const outcome = String(formData.get('outcome') ?? '')
  const ticketId = /^\d+$/.test(idRaw) ? Number(idRaw) : NaN
  if (!Number.isSafeInteger(ticketId) || (outcome !== 'Done' && outcome !== 'No-show')) {
    return { status: 'error', message: 'This ticket could not be updated. Reload the page.' }
  }

  try {
    const profile = await getCurrentProfile()
    if (!profile) return { status: 'error', message: SESSION_ENDED }
    if (profile.role !== 'Registrar') return { status: 'error', message: NOT_ALLOWED }

    const rpc = await queueRpc()
    const { error } = await rpc('queue_finish', { p_ticket_id: ticketId, p_outcome: outcome })
    if (error) return { status: 'error', message: queueErrorMessage(error.code, error.message) }
  } catch {
    return { status: 'error', message: queueErrorMessage(undefined, undefined) }
  }

  revalidatePath('/registrar', 'layout')
  return { status: 'success', message: outcome === 'Done' ? 'Marked as done.' : 'Marked as no-show.' }
}
