'use server'

import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getCurrentTerm } from '@/lib/data/clearance'
import { enrollmentErrorMessage, enrollmentSubmitErrorMessage, enrollmentAddSectionErrorMessage } from '@/lib/data/db-errors'

// Server Actions for the student enrollment screen. They run with the signed-in user's own session: the
// database (RLS, column grants, enrollment triggers) is the final gate; the checks here only give
// friendly messages. status, reviewed_by, reviewed_at, remarks and submitted_at are never sent.
// Success redirects back to the page with a notice (the page re-renders to another view, so a message
// kept inside a form would disappear); errors come back as action state.

export type EnrollmentActionState = {
  status: 'idle' | 'error'
  message: string
  fieldErrors?: { yearLevel?: string; section?: string }
}

const SESSION_ENDED = 'Your session has ended. Please sign in again.'
const GENERIC_SUBMIT = 'We could not submit your enrollment. Please try again in a few minutes.'
const GENERIC_ADD = 'We could not add this section. Please try again in a few minutes.'
const GENERIC_REMOVE = 'We could not remove this section. Please try again in a few minutes.'
const MIN_YEAR = 1
const MAX_YEAR = 6

const err = (message: string, fieldErrors?: EnrollmentActionState['fieldErrors']): EnrollmentActionState => ({
  status: 'error',
  message,
  fieldErrors,
})

const toId = (raw: FormDataEntryValue | null): number => {
  const s = String(raw ?? '').trim()
  return /^\d+$/.test(s) ? Number(s) : NaN
}

// Creates the student's enrollment for the current term. Sends only student_id, term_id and year_level;
// the database sets Pending and the submission time. Sections are added afterwards, on the page.
export async function submitEnrollment(_prev: EnrollmentActionState, formData: FormData): Promise<EnrollmentActionState> {
  void _prev
  const yearLevel = toId(formData.get('yearLevel'))
  if (!Number.isInteger(yearLevel) || yearLevel < MIN_YEAR || yearLevel > MAX_YEAR) {
    return err('Please fix the highlighted field.', { yearLevel: `Choose a year level from ${MIN_YEAR} to ${MAX_YEAR}.` })
  }

  try {
    const supabase = await createClient()
    const { data: userData } = await supabase.auth.getUser()
    const user = userData.user
    if (!user) return err(SESSION_ENDED)

    const term = await getCurrentTerm()
    if (!term) return err('No term is open for enrollment yet.')

    const { data, error } = await supabase
      .from('enrollments')
      .insert({ student_id: user.id, term_id: term.termId, year_level: yearLevel })
      .select('enrollment_id')
    if (error) {
      const mapped = enrollmentSubmitErrorMessage(error.code, error.message, GENERIC_SUBMIT, { min: MIN_YEAR, max: MAX_YEAR })
      return err(mapped.message, mapped.fieldErrors)
    }
    if (!data || data.length === 0) return err(GENERIC_SUBMIT)
  } catch {
    return err(GENERIC_SUBMIT)
  }

  revalidatePath('/student', 'layout')
  redirect('/student/enrollment?notice=submitted')
}

// Adds one section to the student's own Pending enrollment. Sends only enrollment_id and section_id.
export async function addEnrollmentSection(_prev: EnrollmentActionState, formData: FormData): Promise<EnrollmentActionState> {
  void _prev
  const enrollmentId = toId(formData.get('enrollmentId'))
  const sectionId = toId(formData.get('sectionId'))
  if (!Number.isSafeInteger(enrollmentId)) return err('We could not find your enrollment. Reload the page.')
  if (!Number.isSafeInteger(sectionId)) return err('Choose a section to add.', { section: 'Choose a section to add.' })

  try {
    const supabase = await createClient()
    const { data: userData } = await supabase.auth.getUser()
    if (!userData.user) return err(SESSION_ENDED)

    const { error } = await supabase.from('enrollment_items').insert({ enrollment_id: enrollmentId, section_id: sectionId })
    if (error) return err(enrollmentAddSectionErrorMessage(error.code, error.message, GENERIC_ADD))
  } catch {
    return err(GENERIC_ADD)
  }

  revalidatePath('/student', 'layout')
  redirect('/student/enrollment?notice=added')
}

// Removes one section from the student's own Pending enrollment. Deletes by enrollment_item_id (and the
// enrollment id). A delete that RLS or the rules skipped can change 0 rows without an error, so the
// returned rows are checked.
export async function removeEnrollmentSection(_prev: EnrollmentActionState, formData: FormData): Promise<EnrollmentActionState> {
  void _prev
  const itemId = toId(formData.get('enrollmentItemId'))
  const enrollmentId = toId(formData.get('enrollmentId'))
  if (!Number.isSafeInteger(itemId) || !Number.isSafeInteger(enrollmentId)) {
    return err('We could not find that section. Reload the page.')
  }

  try {
    const supabase = await createClient()
    const { data: userData } = await supabase.auth.getUser()
    if (!userData.user) return err(SESSION_ENDED)

    const { data, error } = await supabase
      .from('enrollment_items')
      .delete()
      .eq('enrollment_item_id', itemId)
      .eq('enrollment_id', enrollmentId)
      .select('enrollment_item_id')
    if (error) return err(enrollmentErrorMessage(error.code, error.message, GENERIC_REMOVE))
    if (!data || data.length === 0) {
      return err('This section was not removed. Your enrollment may no longer be Pending, or it was already removed. Reload the page.')
    }
  } catch {
    return err(GENERIC_REMOVE)
  }

  revalidatePath('/student', 'layout')
  redirect('/student/enrollment?notice=removed')
}
