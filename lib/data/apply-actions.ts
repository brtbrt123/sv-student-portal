'use server'

import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { applicationFormErrorMessage } from '@/lib/data/db-errors'

// Server Action for the public enrollment application (/apply). It runs with the anon session only.
// The database rpc submit_application is the final gate; the checks here mirror its rules and give
// friendly messages. A duplicate application for the same email succeeds silently in the database, and
// this action always ends in the same neutral success screen, so nobody can learn whether an email was used.

export type ApplyFields = 'firstName' | 'lastName' | 'email' | 'mobile' | 'programId'

export type ApplyState = {
  status: 'idle' | 'error'
  message: string
  fieldErrors?: Partial<Record<ApplyFields, string>>
  values?: { firstName: string; lastName: string; email: string; mobile: string; programId: string }
}

const GENERIC = 'We could not send your application. Please try again in a few minutes.'
const NAME_RE = /^[\p{L} .'-]+$/u
const MOBILE_RE = /^[0-9+ -]{7,20}$/
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

function checkName(value: string, label: string): string | undefined {
  if (!value) return `Enter your ${label}.`
  if (value.length > 100) return 'This is too long (100 characters at most).'
  if (!NAME_RE.test(value)) return 'Use letters, spaces, hyphens, apostrophes and periods only.'
  return undefined
}

export async function submitApplication(_prev: ApplyState, formData: FormData): Promise<ApplyState> {
  void _prev

  // Honeypot: real people never see or fill this field. Pretend success and do nothing.
  if (String(formData.get('website') ?? '').trim() !== '') redirect('/apply?notice=submitted')

  const firstName = String(formData.get('firstName') ?? '').trim()
  const lastName = String(formData.get('lastName') ?? '').trim()
  const email = String(formData.get('email') ?? '').trim()
  const mobile = String(formData.get('mobile') ?? '').trim()
  const programRaw = String(formData.get('programId') ?? '').trim()
  const values = { firstName, lastName, email, mobile, programId: programRaw }

  const fieldErrors: NonNullable<ApplyState['fieldErrors']> = {}
  const fn = checkName(firstName, 'first name')
  if (fn) fieldErrors.firstName = fn
  const ln = checkName(lastName, 'last name')
  if (ln) fieldErrors.lastName = ln
  if (!email) fieldErrors.email = 'Enter your email address.'
  else if (email.length > 254 || !EMAIL_RE.test(email)) fieldErrors.email = 'Enter a valid email address.'
  if (mobile && !MOBILE_RE.test(mobile)) fieldErrors.mobile = 'Use 7 to 20 digits, spaces, dashes or a leading +.'
  const programId = /^\d+$/.test(programRaw) ? Number(programRaw) : NaN
  if (!Number.isSafeInteger(programId)) fieldErrors.programId = 'Choose the program you are applying for.'

  if (Object.keys(fieldErrors).length > 0) {
    return { status: 'error', message: 'Please fix the highlighted fields.', fieldErrors, values }
  }

  try {
    const supabase = await createClient()
    const rpc = supabase.rpc.bind(supabase) as unknown as (
      fn: string,
      args: Record<string, unknown>
    ) => PromiseLike<{ error: { code?: string; message?: string } | null }>
    const { error } = await rpc('submit_application', {
      p_first_name: firstName,
      p_last_name: lastName,
      p_email: email,
      p_mobile: mobile === '' ? null : mobile,
      p_program_id: programId,
    })
    if (error) return { status: 'error', message: applicationFormErrorMessage(error.code, error.message, GENERIC), values }
  } catch {
    return { status: 'error', message: GENERIC, values }
  }

  redirect('/apply?notice=submitted')
}
