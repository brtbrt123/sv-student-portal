'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { getCurrentProfile } from '@/lib/auth/session'
import { enrollmentDecisionErrorMessage } from '@/lib/data/db-errors'

// Server Action for the Registrar's enrollment decision. It runs with the signed-in user's own session:
// the database (RLS, column grants, enrollment rules trigger) is the final gate; the checks here only
// give friendly messages. Only status (and remarks, when typed) is sent: reviewed_by and reviewed_at
// are set by the database, never by this code.

export type DecideEnrollmentState = { status: 'idle' | 'success' | 'error'; message: string }

const SESSION_ENDED = 'Your session has ended. Please sign in again.'
const GENERIC = 'We could not save the decision. Please try again in a few minutes.'
const MAX_REMARKS = 300
const GENERIC_DROP = 'We could not drop the subject. Please try again in a few minutes.'

// Approves or rejects one Pending enrollment. The update is limited to the status the Registrar saw
// (`from`, always Pending), so an enrollment someone else decided meanwhile is reported, not overwritten.
export async function decideEnrollment(_prev: DecideEnrollmentState, formData: FormData): Promise<DecideEnrollmentState> {
  void _prev
  const idRaw = String(formData.get('enrollmentId') ?? '')
  const fromRaw = String(formData.get('from') ?? '')
  const target = String(formData.get('status') ?? '')
  const remarks = String(formData.get('remarks') ?? '').trim()
  const enrollmentId = /^\d+$/.test(idRaw) ? Number(idRaw) : NaN

  if (!Number.isSafeInteger(enrollmentId) || fromRaw !== 'Pending' || (target !== 'Approved' && target !== 'Rejected')) {
    return { status: 'error', message: 'That decision is not allowed. Only Pending enrollments can be decided. Reload the page.' }
  }
  if (remarks.length > MAX_REMARKS) {
    return { status: 'error', message: `The remarks are too long (${MAX_REMARKS} characters at most).` }
  }
  if (target === 'Rejected' && !remarks) {
    return { status: 'error', message: 'Add a remark that tells the student why the enrollment is rejected.' }
  }

  try {
    const profile = await getCurrentProfile()
    if (!profile || profile.role !== 'Registrar') return { status: 'error', message: SESSION_ENDED }
    const supabase = await createClient()

    const patch: { status: string; remarks?: string } = { status: target }
    if (remarks) patch.remarks = remarks

    // .select() returns the updated rows, so a change that RLS or the status filter skipped shows up as no rows.
    const { data: updated, error } = await supabase
      .from('enrollments')
      .update(patch)
      .eq('enrollment_id', enrollmentId)
      .eq('status', 'Pending')
      .select('enrollment_id')
    if (error) return { status: 'error', message: enrollmentDecisionErrorMessage(error.code, error.message, error.details) }
    if (!updated || updated.length === 0) {
      return { status: 'error', message: 'This enrollment was not changed. Someone may have decided it already. Reload the page.' }
    }
  } catch {
    return { status: 'error', message: GENERIC }
  }

  revalidatePath('/registrar', 'layout')
  revalidatePath('/student', 'layout')
  return { status: 'success', message: `Enrollment ${target.toLowerCase()}.` }
}

// A student whose subjects are set by their program cannot drop one; the Registrar does it on request, with their
// OWN session: the database policy enrollment_items_registrar_delete lets an active Registrar delete an item, the
// trigger refuses a change to an enrollment that is not Pending (for every role), and the audit log records the
// Registrar as the actor. No server key is used.
export async function dropEnrollmentSection(_prev: DecideEnrollmentState, formData: FormData): Promise<DecideEnrollmentState> {
  void _prev
  const enrollmentRaw = String(formData.get('enrollmentId') ?? '')
  const itemRaw = String(formData.get('enrollmentItemId') ?? '')
  const enrollmentId = /^\d+$/.test(enrollmentRaw) ? Number(enrollmentRaw) : NaN
  const itemId = /^\d+$/.test(itemRaw) ? Number(itemRaw) : NaN
  if (!Number.isSafeInteger(enrollmentId) || !Number.isSafeInteger(itemId)) {
    return { status: 'error', message: 'That subject could not be dropped. Reload the page.' }
  }

  try {
    const profile = await getCurrentProfile()
    if (!profile || profile.role !== 'Registrar') return { status: 'error', message: SESSION_ENDED }
    const supabase = await createClient()

    // .select() returns the deleted rows, so a delete that RLS skipped shows up as no rows.
    const { data: removed, error } = await supabase
      .from('enrollment_items')
      .delete()
      .eq('enrollment_item_id', itemId)
      .eq('enrollment_id', enrollmentId)
      .select('enrollment_item_id')
    if (error) {
      if (error.code === 'P0001' && error.message?.startsWith('enrollment locked:')) {
        return { status: 'error', message: 'Only a Pending enrollment can change. This one was already decided. Reload the page.' }
      }
      return { status: 'error', message: GENERIC_DROP }
    }
    if (!removed || removed.length === 0) {
      return { status: 'error', message: 'That subject was not found or cannot be dropped. It may be dropped already. Reload the page.' }
    }
  } catch {
    return { status: 'error', message: GENERIC_DROP }
  }

  revalidatePath('/registrar', 'layout')
  revalidatePath('/student', 'layout')
  return { status: 'success', message: 'Subject dropped.' }
}
