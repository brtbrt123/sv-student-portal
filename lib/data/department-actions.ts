'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { getMyDepartment } from '@/lib/data/department'
import { departmentApproveErrorMessage, departmentHoldErrorMessage, departmentReviewErrorMessage, departmentLiftHoldErrorMessage } from '@/lib/data/db-errors'

// Writes for the Department screens. Everything runs with the signed-in user's own session: Row Level
// Security and the database triggers decide what is allowed, and the "by" columns always carry the
// signed-in user's id. Timestamps are taken on the server when the action runs, never from the client.

export type DeptActionState = {
  status: 'idle' | 'success' | 'error'
  message: string
  /** Changes with every response, so the screen can reset or reopen things per result. */
  stamp: number
  /** Which field the message belongs to (place-hold form only). */
  field?: 'student' | 'reason'
  /** Echo of what was typed, so a failed submit does not lose it. */
  values?: { studentId: string; reason: string }
}

const GENERIC = 'Something went wrong on our side. Please try again in a few minutes.'
const SESSION_ENDED = 'Your session has ended. Please sign in again.'

function fail(message: string, extra: Partial<DeptActionState> = {}): DeptActionState {
  return { status: 'error', message, stamp: Date.now(), ...extra }
}

function ok(message: string): DeptActionState {
  return { status: 'success', message, stamp: Date.now() }
}

function text(formData: FormData, key: string, max: number): string {
  const v = formData.get(key)
  return typeof v === 'string' ? v.trim().slice(0, max) : ''
}

function positiveInt(formData: FormData, key: string): number | null {
  const n = Number(formData.get(key))
  return Number.isInteger(n) && n > 0 ? n : null
}

async function currentUserId(): Promise<string | null> {
  const supabase = await createClient()
  const { data } = await supabase.auth.getUser()
  return data.user?.id ?? null
}

// Approve (sets cleared_at and cleared_by) or reject (writes remarks only; the item stays pending and
// the student sees the remarks) a clearance item of the signed-in department.
export async function reviewItem(_prev: DeptActionState, formData: FormData): Promise<DeptActionState> {
  try {
    const userId = await currentUserId()
    if (!userId) return fail(SESSION_ENDED)

    const itemId = positiveInt(formData, 'itemId')
    const intent = text(formData, 'intent', 10)
    const studentName = text(formData, 'studentName', 80) || 'This student'
    if (itemId === null || (intent !== 'approve' && intent !== 'reject')) return fail(GENERIC)

    const supabase = await createClient()

    if (intent === 'reject') {
      const remarks = text(formData, 'remarks', 500)
      if (!remarks) return fail('Enter the reason for rejecting this item.')
      const { data, error } = await supabase
        .from('clearance_items')
        .update({ remarks })
        .eq('clearance_item_id', itemId)
        .is('cleared_at', null)
        .select('clearance_item_id')
      if (error) return fail(departmentReviewErrorMessage(error.code))
      if (!data || data.length === 0) return fail('This item was already cleared or is no longer available.')
      revalidatePath('/department', 'layout')
      return ok(`Rejected for ${studentName}. The student can see your remarks; the item stays pending.`)
    }

    const { data, error } = await supabase
      .from('clearance_items')
      .update({ cleared_at: new Date().toISOString(), cleared_by: userId })
      .eq('clearance_item_id', itemId)
      .is('cleared_at', null)
      .select('clearance_item_id')
    if (error) return fail(departmentApproveErrorMessage(error, studentName))
    if (!data || data.length === 0) return fail('This item was already cleared or is no longer available.')
    revalidatePath('/department', 'layout')
    return ok(`Approved for ${studentName}.`)
  } catch {
    return fail(GENERIC)
  }
}

// Places an academic hold from the signed-in department on a student (reason required).
export async function placeHold(_prev: DeptActionState, formData: FormData): Promise<DeptActionState> {
  const studentId = text(formData, 'studentId', 64)
  const reason = text(formData, 'reason', 300)
  const values = { studentId, reason }
  try {
    if (!studentId) return fail('Choose a student.', { field: 'student', values })
    if (!reason) return fail('Enter the reason for the hold.', { field: 'reason', values })

    const userId = await currentUserId()
    if (!userId) return fail(SESSION_ENDED, { values })
    const mine = await getMyDepartment()
    if (!mine) return fail('Your account is not linked to a department yet. Ask an administrator.', { values })

    const supabase = await createClient()
    const { error } = await supabase.from('academic_holds').insert({
      student_id: studentId,
      department_id: mine.department.id,
      reason,
      placed_by: userId,
    })
    if (error) return fail(departmentHoldErrorMessage(error), { values })
    revalidatePath('/department', 'layout')
    revalidatePath('/student', 'layout')
    return ok('Hold placed. The student will see it, and approval is blocked until you lift it.')
  } catch {
    return fail(GENERIC, { values })
  }
}

// Lifts one of the department's active holds (lifted_at = server now, lifted_by = signed-in user).
export async function liftHold(_prev: DeptActionState, formData: FormData): Promise<DeptActionState> {
  try {
    const userId = await currentUserId()
    if (!userId) return fail(SESSION_ENDED)
    const holdId = positiveInt(formData, 'holdId')
    const studentName = text(formData, 'studentName', 80) || 'the student'
    if (holdId === null) return fail(GENERIC)

    const supabase = await createClient()
    const { data, error } = await supabase
      .from('academic_holds')
      .update({ lifted_at: new Date().toISOString(), lifted_by: userId })
      .eq('hold_id', holdId)
      .is('lifted_at', null)
      .select('hold_id')
    if (error) return fail(departmentLiftHoldErrorMessage(error.code))
    if (!data || data.length === 0) return fail('This hold was already lifted or is no longer available.')
    revalidatePath('/department', 'layout')
    revalidatePath('/student', 'layout')
    return ok(`Hold lifted for ${studentName}. You can approve the item now.`)
  } catch {
    return fail(GENERIC)
  }
}
