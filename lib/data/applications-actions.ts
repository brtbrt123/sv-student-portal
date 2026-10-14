'use server'

import { randomBytes } from 'node:crypto'
import { revalidatePath } from 'next/cache'
import { headers } from 'next/headers'
import type { SupabaseClient } from '@supabase/supabase-js'
import { createClient } from '@/lib/supabase/server'
import { getCurrentProfile } from '@/lib/auth/session'
import { getAdminClientFor } from '@/lib/supabase/admin'
import { acceptanceEmail, rejectionEmail, sendMail } from '@/lib/mail'
import { studentIdToEmail } from '@/lib/auth/student-id'
import { APPLICATION_COLUMNS } from '@/lib/data/applications'
import { applicationDecisionErrorMessage } from '@/lib/data/db-errors'

// Server Actions for the Registrar's applications screen.
//
// Decisions (Accept, Reject) run with the signed-in Registrar's own session: the database (RLS, column
// grants, status trigger) is the final gate. Only status and remarks are sent; reviewed_by and
// reviewed_at are set by the database.
//
// Account setup (provisioning) and the set-password email need the admin client, which is only handed
// out by getAdminClientFor('Registrar') after the caller's session proves a signed-in, active
// Registrar. Every step is retry-safe: the application gets its student_id only as the LAST step,
// and any failure before that undoes what was created, so "Retry account setup" starts clean.
// Nothing here returns, logs or emails a password or a key.

export type ApplicationActionState = { status: 'idle' | 'success' | 'warning' | 'error'; message: string }

type Db = SupabaseClient

type AppRow = {
  application_id: string | number
  first_name: string | null
  last_name: string | null
  email: string | null
  program_id: number | null
  status: string
  student_id: string | null
}

type Provisioned = { ok: true; studentId: string; studentNumber: string } | { ok: false; message: string }

const SESSION_ENDED = 'Your session has ended. Please sign in again.'
const GENERIC = 'We could not save the decision. Please try again in a few minutes.'
const NOT_CONFIGURED = 'Account setup is not configured on the server yet. Ask the Admin, then try again.'
const NOT_FOUND = 'We could not find this application. Reload the page.'
const SETUP_FAILED =
  'The application is Accepted, but the student account could not be created. Use "Retry account setup" in a few minutes.'
const EMAIL_IN_USE =
  "The applicant's email address is already used by another portal account, so no student account was created. " +
  'The application stays Accepted. Ask the Admin to check the existing account, then use "Retry account setup".'
const MAX_REMARKS = 300

// application_id may be a number or a uuid; both are passed to the database as text, never in SQL.
const ID_RE = /^(\d{1,18}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i
const STUDENT_NUMBER_RE = /^\d{4}-\d{4,6}$/
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

const fail = (message: string): ApplicationActionState => ({ status: 'error', message })

// Server-log only: which provisioning step failed and the database or Auth error code and message
// (never a key, a password or the applicant's data).
const logStep = (step: string, error: { code?: string; status?: number; message?: string } | null | undefined) =>
  console.error(`[provisioning] ${step}:`, error?.code ?? error?.status ?? '-', error?.message ?? 'no detail')

function readId(formData: FormData): string | null {
  const raw = String(formData.get('applicationId') ?? '').trim()
  return ID_RE.test(raw) ? raw : null
}

// A long random password nobody ever sees: it is not stored, shown or emailed. The student sets their
// own password through the one-time link.
function throwawayPassword(): string {
  return `${randomBytes(32).toString('base64url')}aA1!`
}

// Where the set-password link points. SITE_URL wins; otherwise the current request's host (https,
// except on localhost). Returns null when the host looks wrong, so no odd link is ever emailed.
async function siteUrl(): Promise<string | null> {
  const env = process.env.SITE_URL?.trim()
  if (env) {
    try {
      const u = new URL(env)
      if (u.protocol === 'https:' || u.protocol === 'http:') return u.origin
    } catch {
      // fall through to the request host
    }
  }
  const h = await headers()
  const host = (h.get('x-forwarded-host') ?? h.get('host') ?? '').split(',')[0].trim()
  if (!/^[a-z0-9.-]+(:\d{1,5})?$/i.test(host)) return null
  const local = /^(localhost|127\.0\.0\.1)(:\d+)?$/i.test(host)
  return `${local ? 'http' : 'https'}://${host}`
}

async function readApplication(db: Db, id: string): Promise<AppRow | null> {
  const { data, error } = await db.from('applications').select(APPLICATION_COLUMNS).eq('application_id', id).maybeSingle()
  if (error || !data) return null
  return data as AppRow
}

// Best-effort undo of a half-created account, in foreign-key order. Returns false if anything is left.
async function undoAccount(admin: Db, userId: string): Promise<boolean> {
  let clean = true
  try {
    const s = await admin.from('students').delete().eq('student_id', userId)
    if (s.error) clean = false
    const p = await admin.from('profiles').delete().eq('profile_id', userId)
    if (p.error) clean = false
    const u = await admin.auth.admin.deleteUser(userId)
    if (u.error) clean = false
  } catch {
    clean = false
  }
  return clean
}

// Creates the Auth user, profile and student rows for an Accepted application that has none yet, then
// links them to the application. The caller has already verified the Registrar.
async function provision(admin: Db, app: AppRow): Promise<Provisioned> {
  const email = (app.email ?? '').trim()
  const firstName = (app.first_name ?? '').trim()
  const lastName = (app.last_name ?? '').trim()
  if (!EMAIL_RE.test(email) || !firstName || !lastName || app.program_id === null) {
    return { ok: false, message: 'This application is missing a name, email or program, so no account was created. Ask the Admin.' }
  }

  // The real email must be free: profiles.email is unique. Checked first so nothing is created in vain.
  const inUse = await admin.from('profiles').select('profile_id').in('email', [...new Set([email, email.toLowerCase()])]).limit(1)
  if (inUse.error) { logStep('check email in profiles', inUse.error); return { ok: false, message: SETUP_FAILED } }
  if ((inUse.data ?? []).length > 0) return { ok: false, message: EMAIL_IN_USE }

  const role = await admin.from('roles').select('role_id').eq('role_name', 'Student').maybeSingle()
  if (role.error || !role.data) { logStep('read Student role', role.error); return { ok: false, message: SETUP_FAILED } }
  const roleId = (role.data as { role_id: number }).role_id

  const num = await admin.rpc('next_student_number')
  const studentNumber = typeof num.data === 'string' ? num.data.trim() : ''
  if (num.error || !STUDENT_NUMBER_RE.test(studentNumber)) { logStep('next_student_number', num.error ?? { message: 'unexpected value' }); return { ok: false, message: SETUP_FAILED } }

  const created = await admin.auth.admin.createUser({
    email: studentIdToEmail(studentNumber),
    email_confirm: true,
    password: throwawayPassword(),
  })
  const userId = created.data?.user?.id
  if (created.error || !userId) { logStep('create auth user', created.error ?? { message: 'no user returned' }); return { ok: false, message: SETUP_FAILED } }

  const undo = async (cleanMessage: string): Promise<Provisioned> => {
    const clean = await undoAccount(admin, userId)
    return {
      ok: false,
      message: clean
        ? cleanMessage
        : `Account setup stopped halfway and could not be fully undone. Ask the Admin to check student ID ${studentNumber} before retrying.`,
    }
  }

  const prof = await admin.from('profiles').insert({
    profile_id: userId,
    role_id: roleId,
    first_name: firstName,
    last_name: lastName,
    email,
    is_active: true,
  })
  if (prof.error) logStep('insert profile', prof.error)
  if (prof.error) return undo(prof.error.code === '23505' ? EMAIL_IN_USE : SETUP_FAILED)

  const stu = await admin.from('students').insert({
    student_id: userId,
    student_number: studentNumber,
    program_id: app.program_id,
  })
  if (stu.error) logStep('insert student', stu.error)
  if (stu.error) return undo(SETUP_FAILED)

  // Link last, and only if nobody else linked it meanwhile (two clicks, two Registrars).
  const link = await admin
    .from('applications')
    .update({ student_id: userId, provisioned_at: new Date().toISOString() })
    .eq('application_id', String(app.application_id))
    .eq('status', 'Accepted')
    .is('student_id', null)
    .select('application_id')
  if (link.error || !link.data || link.data.length === 0) {
    logStep('link application', link.error ?? { message: 'no row updated' })
    return undo('The account was not linked. Someone may have set it up already. Reload the page.')
  }

  return { ok: true, studentId: userId, studentNumber }
}

// Generates a NEW one-time set-password link (a link works once) and emails it with the student ID to
// the applicant's real email. Returns false when the link or the email failed; nothing is undone.
async function sendCredentials(admin: Db, app: AppRow, studentId: string, studentNumber: string): Promise<boolean> {
  try {
    const email = (app.email ?? '').trim()
    if (!EMAIL_RE.test(email)) return false
    const site = await siteUrl()
    if (!site) return false

    const gen = await admin.auth.admin.generateLink({ type: 'recovery', email: studentIdToEmail(studentNumber) })
    const hashed = gen.data?.properties?.hashed_token
    // The link must belong to this application's account, never to another user.
    if (gen.error || !hashed || gen.data?.user?.id !== studentId) return false

    const link = `${site}/auth/confirm?token_hash=${encodeURIComponent(hashed)}&type=recovery`
    await sendMail({ to: email, ...acceptanceEmail((app.first_name ?? '').trim() || 'there', studentNumber, link) })
    return true
  } catch {
    return false
  }
}

async function studentNumberOf(db: Db, studentId: string): Promise<string | null> {
  const { data, error } = await db.from('students').select('student_number').eq('student_id', studentId).maybeSingle()
  if (error || !data) return null
  const n = (data as { student_number: string }).student_number
  return STUDENT_NUMBER_RE.test(n) ? n : null
}

// Provisions when needed, then emails. Shared by Accept and Retry.
async function setUpAndEmail(admin: Db, app: AppRow): Promise<ApplicationActionState> {
  let studentId = app.student_id
  let studentNumber: string | null = null
  if (!studentId) {
    const result = await provision(admin, app)
    if (!result.ok) return fail(result.message)
    studentId = result.studentId
    studentNumber = result.studentNumber
  } else {
    studentNumber = await studentNumberOf(admin, studentId)
    if (!studentNumber) return fail(SETUP_FAILED)
  }

  const sent = await sendCredentials(admin, app, studentId, studentNumber)
  if (!sent) {
    return { status: 'warning', message: `Account created (student ID ${studentNumber}) but the email failed: use "Resend email".` }
  }
  return {
    status: 'success',
    message: `Student ID ${studentNumber} is ready. The set-password email was sent to ${(app.email ?? '').trim()}.`,
  }
}

function revalidate() {
  revalidatePath('/registrar', 'layout')
}

// Accepts one Pending application, then sets up the student account and emails the student ID with a
// one-time set-password link.
export async function acceptApplication(_prev: ApplicationActionState, formData: FormData): Promise<ApplicationActionState> {
  void _prev
  const id = readId(formData)
  const remarks = String(formData.get('remarks') ?? '').trim()
  if (!id) return fail('That decision is not allowed. Reload the page.')
  if (remarks.length > MAX_REMARKS) return fail(`The remarks are too long (${MAX_REMARKS} characters at most).`)

  let result: ApplicationActionState
  try {
    // Verifies the signed-in, active Registrar BEFORE anything else happens.
    const ctx = await getAdminClientFor('Registrar').catch(() => undefined)
    if (ctx === undefined) return fail(NOT_CONFIGURED)
    if (ctx === null) return fail(SESSION_ENDED)

    const db = (await createClient()) as unknown as Db
    const patch: { status: string; remarks?: string } = { status: 'Accepted' }
    if (remarks) patch.remarks = remarks

    // .select() returns the updated rows, so a change that RLS or the status filter skipped shows up as no rows.
    const { data: updated, error } = await db
      .from('applications')
      .update(patch)
      .eq('application_id', id)
      .eq('status', 'Pending')
      .select('application_id')
    if (error) return fail(applicationDecisionErrorMessage(error.code, error.message))
    if (!updated || updated.length === 0) {
      return fail('This application was not changed. Someone may have decided it already. Reload the page.')
    }

    const app = await readApplication(db, id)
    result = app ? await setUpAndEmail(ctx.admin, app) : fail(SETUP_FAILED)
  } catch {
    result = fail(SETUP_FAILED)
  }

  revalidate()
  return result
}

// For an Accepted application whose account setup failed earlier: tries again from a clean state.
export async function retryProvisioning(_prev: ApplicationActionState, formData: FormData): Promise<ApplicationActionState> {
  void _prev
  const id = readId(formData)
  if (!id) return fail(NOT_FOUND)

  let result: ApplicationActionState
  try {
    const ctx = await getAdminClientFor('Registrar').catch(() => undefined)
    if (ctx === undefined) return fail(NOT_CONFIGURED)
    if (ctx === null) return fail(SESSION_ENDED)

    const db = (await createClient()) as unknown as Db
    const app = await readApplication(db, id)
    if (!app) return fail(NOT_FOUND)
    if (app.status !== 'Accepted') return fail('Only Accepted applications get a student account. Reload the page.')
    if (app.student_id) {
      result = { status: 'success', message: 'This account is already set up. Use "Resend email" if the applicant needs a new link.' }
    } else {
      result = await setUpAndEmail(ctx.admin, app)
    }
  } catch {
    result = fail(SETUP_FAILED)
  }

  revalidate()
  return result
}

// Sends the student ID again with a NEW one-time link (the old one may be used or expired).
export async function resendCredentials(_prev: ApplicationActionState, formData: FormData): Promise<ApplicationActionState> {
  void _prev
  const id = readId(formData)
  if (!id) return fail(NOT_FOUND)

  try {
    const ctx = await getAdminClientFor('Registrar').catch(() => undefined)
    if (ctx === undefined) return fail(NOT_CONFIGURED)
    if (ctx === null) return fail(SESSION_ENDED)

    const db = (await createClient()) as unknown as Db
    const app = await readApplication(db, id)
    if (!app) return fail(NOT_FOUND)
    if (app.status !== 'Accepted' || !app.student_id) {
      return fail('This application has no student account yet. Use "Retry account setup" first.')
    }
    const studentNumber = await studentNumberOf(db, app.student_id)
    if (!studentNumber) return fail('We could not read the student ID for this account. Reload the page.')

    const sent = await sendCredentials(ctx.admin, app, app.student_id, studentNumber)
    if (!sent) return fail('The email could not be sent. Please try again in a few minutes.')
    return { status: 'success', message: `A new set-password email was sent to ${(app.email ?? '').trim()}.` }
  } catch {
    return fail('The email could not be sent. Please try again in a few minutes.')
  }
}

// Rejects one Pending application (remarks required) and, when asked, emails a plain notice.
// Uses the Registrar's own session only; no admin client.
export async function rejectApplication(_prev: ApplicationActionState, formData: FormData): Promise<ApplicationActionState> {
  void _prev
  const id = readId(formData)
  const remarks = String(formData.get('remarks') ?? '').trim()
  const notify = formData.get('notify') === 'on'
  if (!id) return fail('That decision is not allowed. Reload the page.')
  if (!remarks) return fail('Add a remark that tells the applicant why the application is rejected.')
  if (remarks.length > MAX_REMARKS) return fail(`The remarks are too long (${MAX_REMARKS} characters at most).`)

  let app: AppRow | null
  try {
    const profile = await getCurrentProfile()
    if (!profile || profile.role !== 'Registrar') return fail(SESSION_ENDED)
    const db = (await createClient()) as unknown as Db

    const { data: updated, error } = await db
      .from('applications')
      .update({ status: 'Rejected', remarks })
      .eq('application_id', id)
      .eq('status', 'Pending')
      .select(APPLICATION_COLUMNS)
    if (error) return fail(applicationDecisionErrorMessage(error.code, error.message))
    if (!updated || updated.length === 0) {
      return fail('This application was not changed. Someone may have decided it already. Reload the page.')
    }
    app = updated[0] as AppRow
  } catch {
    return fail(GENERIC)
  }

  revalidate()

  if (!notify) return { status: 'success', message: 'Application rejected.' }
  const email = (app.email ?? '').trim()
  try {
    if (!EMAIL_RE.test(email)) throw new Error('bad email')
    await sendMail({ to: email, ...rejectionEmail((app.first_name ?? '').trim() || 'there', remarks) })
    return { status: 'success', message: `Application rejected. A notice was emailed to ${email}.` }
  } catch {
    return { status: 'warning', message: 'Application rejected, but the notice email could not be sent. You may contact the applicant directly.' }
  }
}
