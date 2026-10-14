'use server'

import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getCurrentProfile } from '@/lib/auth/session'
import { DOCUMENT_STATUSES, NEXT_STATUSES, type DocumentStatus } from '@/lib/data/documents'
import { documentStatusErrorMessage, documentRequestErrorMessage } from '@/lib/data/db-errors'

// Server Actions for document requests. They run with the signed-in user's own session: the database
// (RLS, column grants, status trigger) is the final gate; the checks here only give friendly messages.
// Ticket number, status on insert, processed_by and processed_at are set by the database, never sent.

export type RequestDocumentState = {
  status: 'idle' | 'error'
  message: string
  fieldErrors?: { type?: string; purpose?: string; copies?: string }
}

export type UpdateDocumentState = { status: 'idle' | 'success' | 'error'; message: string }

const SESSION_ENDED = 'Your session has ended. Please sign in again.'
const GENERIC_REQUEST = 'We could not send your request. Please try again in a few minutes.'
const GENERIC_UPDATE = 'We could not update this request. Please try again in a few minutes.'
const MAX_PURPOSE = 200
const MAX_REMARKS = 300
const MAX_COPIES = 10
const MAX_TYPES = 5

// Files document requests for the signed-in student: one request row per document type picked (up to MAX_TYPES),
// all with the same purpose and copies, in ONE insert so they all succeed or none does. The student still gets one
// queue number at the window for all of them (the queue ticket belongs to the student, not to a request). Sends only
// student_id, document_type_id, purpose and copies. On success the student goes back to the page with a notice (the page re-renders, so a
// message kept in the form would disappear).
export async function requestDocument(_prev: RequestDocumentState, formData: FormData): Promise<RequestDocumentState> {
  void _prev
  const err = (message: string, fieldErrors?: RequestDocumentState['fieldErrors']): RequestDocumentState => ({
    status: 'error',
    message,
    fieldErrors,
  })

  const typeRaws = formData.getAll('documentTypeId').map((v) => String(v))
  const purpose = String(formData.get('purpose') ?? '').trim()
  const copiesRaw = String(formData.get('copies') ?? '').trim()

  const fieldErrors: NonNullable<RequestDocumentState['fieldErrors']> = {}
  const typeIds = [...new Set(typeRaws.map((raw) => (/^\d+$/.test(raw) ? Number(raw) : NaN)))]
  if (typeIds.length === 0 || typeIds.some((id) => !Number.isSafeInteger(id))) fieldErrors.type = 'Choose the document you need.'
  else if (typeIds.length > MAX_TYPES) fieldErrors.type = `Choose up to ${MAX_TYPES} documents at a time.`
  if (!purpose) fieldErrors.purpose = 'Enter the purpose of the request.'
  else if (purpose.length > MAX_PURPOSE) fieldErrors.purpose = `The purpose is too long (${MAX_PURPOSE} characters at most).`
  const copies = /^\d+$/.test(copiesRaw) ? Number(copiesRaw) : NaN
  if (!Number.isInteger(copies) || copies < 1 || copies > MAX_COPIES) fieldErrors.copies = `Copies must be from 1 to ${MAX_COPIES}.`
  if (Object.keys(fieldErrors).length > 0) return err('Please fix the highlighted fields.', fieldErrors)

  try {
    const supabase = await createClient()
    const { data: userData } = await supabase.auth.getUser()
    const user = userData.user
    if (!user) return err(SESSION_ENDED)

    const { error } = await supabase.from('document_requests').insert(
      typeIds.map((typeId) => ({
        student_id: user.id,
        document_type_id: typeId,
        purpose,
        copies,
      }))
    )
    if (error) {
      const mapped = documentRequestErrorMessage(error.code, GENERIC_REQUEST)
      return err(mapped.message, mapped.fieldErrors)
    }
  } catch {
    return err(GENERIC_REQUEST)
  }

  revalidatePath('/student', 'layout')
  redirect('/student/documents?notice=requested')
}

// Moves one request to its next legal status. Sends only status and, when typed, remarks (never
// processed_by or processed_at: the database stamps them). The update is limited to the status the
// Registrar saw (`from`), so a request someone else changed meanwhile is reported, not overwritten.
export async function updateDocumentStatus(_prev: UpdateDocumentState, formData: FormData): Promise<UpdateDocumentState> {
  void _prev
  const idRaw = String(formData.get('requestId') ?? '')
  const fromRaw = String(formData.get('from') ?? '')
  const targetRaw = String(formData.get('status') ?? '')
  const remarks = String(formData.get('remarks') ?? '').trim()
  const requestId = /^\d+$/.test(idRaw) ? Number(idRaw) : NaN

  const known = (s: string): s is DocumentStatus => (DOCUMENT_STATUSES as readonly string[]).includes(s)
  if (!Number.isSafeInteger(requestId) || !known(fromRaw) || !known(targetRaw) || !NEXT_STATUSES[fromRaw].includes(targetRaw)) {
    return { status: 'error', message: 'That status change is not allowed. Reload the page.' }
  }
  const from: DocumentStatus = fromRaw
  const target: DocumentStatus = targetRaw
  if (remarks.length > MAX_REMARKS) {
    return { status: 'error', message: `The remarks are too long (${MAX_REMARKS} characters at most).` }
  }
  if (target === 'Rejected' && !remarks) {
    return { status: 'error', message: 'Add a remark that tells the student why the request is rejected.' }
  }

  try {
    const profile = await getCurrentProfile()
    if (!profile || profile.role !== 'Registrar') return { status: 'error', message: SESSION_ENDED }
    const supabase = await createClient()

    // Remarks are sent together with the status change (the database refuses remarks-only edits while
    // Pending). Left empty, they are not sent, so earlier remarks stay.
    const patch: { status: string; remarks?: string } = { status: target }
    if (remarks) patch.remarks = remarks

    // .select() returns the updated rows, so a change that RLS or the status filter skipped shows up as no rows.
    const { data: updated, error } = await supabase
      .from('document_requests')
      .update(patch)
      .eq('request_id', requestId)
      .eq('status', from)
      .select('request_id')
    if (error) return { status: 'error', message: documentStatusErrorMessage(error.code, error.message) }
    if (!updated || updated.length === 0) {
      return { status: 'error', message: 'This request was not changed. Someone may have updated it already. Reload the page.' }
    }
  } catch {
    return { status: 'error', message: GENERIC_UPDATE }
  }

  revalidatePath('/registrar', 'layout')
  revalidatePath('/student', 'layout')
  return { status: 'success', message: `Request is now ${target}.` }
}
