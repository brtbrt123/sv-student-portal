'use server'

import { randomBytes } from 'node:crypto'
import { revalidatePath } from 'next/cache'
import { headers } from 'next/headers'
import type { SupabaseClient } from '@supabase/supabase-js'
import { createClient } from '@/lib/supabase/server'
import { getAdminClientFor } from '@/lib/supabase/admin'
import { isRoleName, type RoleName } from '@/lib/auth/roles'
import { sendMail, staffWelcomeEmail } from '@/lib/mail'

// Server Actions for the Admin's Users screen (REQ-ADM-01). Decision record:
// docs/decisions/sprint4-admin-users.md. Database side: docs/database/admin_users.sql.
//
// Every action starts with getAdminClientFor('Admin'): it proves, from the caller's own session, a
// signed-in, ACTIVE Admin before anything else happens, and only then hands out the admin client
// (the key that bypasses RLS; it never leaves lib/supabase/admin.ts). The admin client is used for
// what the Admin's session cannot do: Supabase Auth (create user, ban, recovery link), and the
// profiles INSERT / DELETE that only the server may do. Everything else (editing a profile, the
// department assignment) runs with the Admin's OWN session, so RLS, the column grants and the
// last-admin trigger stay the final gate. Nothing here returns, logs or emails a password or a key.

export type AdminUserActionState = { status: 'idle' | 'success' | 'warning' | 'error'; message: string }

type Db = SupabaseClient

const SESSION_ENDED = 'Your session has ended. Please sign in again.'
const NOT_ALLOWED = 'Your account is not allowed to do this.'
const NOT_CONFIGURED = 'Account administration is not configured on the server yet. Ask the site owner, then try again.'
const GENERIC = 'We could not save the change. Please try again in a few minutes.'
const NOT_FOUND = 'We could not find this account. Reload the page.'
const LAST_ADMIN = 'This is the only active Admin account. Make another account an active Admin first.'
const EMAIL_IN_USE = 'That email address is already used by another account.'
const BAN_FOREVER = '876000h' // about 100 years: Supabase has no "ban forever" value

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const MAX_NAME = 80
const MAX_EMAIL = 254

const fail = (message: string): AdminUserActionState => ({ status: 'error', message })

// Server-log only: which step failed and the database or Auth error code and message (never a key,
// a password or the person's data).
const logStep = (step: string, error: { code?: string; status?: number; message?: string } | null | undefined) =>
  console.error(`[admin-users] ${step}:`, error?.code ?? error?.status ?? '-', error?.message ?? 'no detail')

function friendly(error: { code?: string; message?: string }): string {
  if (error.code === 'P0001' && error.message?.startsWith('last admin:')) return LAST_ADMIN
  if (error.code === '42501') return NOT_ALLOWED
  return GENERIC
}

function readUserId(formData: FormData): string | null {
  const raw = String(formData.get('userId') ?? '').trim()
  return UUID_RE.test(raw) ? raw : null
}

function readName(formData: FormData, key: string): string | null {
  const v = String(formData.get(key) ?? '').trim().replace(/\s+/g, ' ')
  return v.length >= 1 && v.length <= MAX_NAME ? v : null
}

function readRole(formData: FormData): RoleName | null {
  const v = String(formData.get('role') ?? '').trim()
  return isRoleName(v) ? v : null
}

function readDepartmentId(formData: FormData): number | null {
  const raw = String(formData.get('departmentId') ?? '').trim()
  return /^\d{1,9}$/.test(raw) ? Number(raw) : null
}

// A long random password nobody ever sees: not stored, shown or emailed. The person sets their own
// through the one-time link.
function throwawayPassword(): string {
  return `${randomBytes(32).toString('base64url')}aA1!`
}

// Where the set-password link points: SITE_URL, else the current request's host (same rules as the
// Registrar's acceptance email in applications-actions.ts). Null when the host looks wrong.
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

// The department a role needs (design decision 2 of admin_users.sql): Department = one
// Academic department, Cashier = the Financial department, every other role = none.
const DEPARTMENT_TYPE: Partial<Record<RoleName, 'Academic' | 'Financial'>> = {
  Department: 'Academic',
  Cashier: 'Financial',
}

type RoleRow = { role_id: number; role_name: string }

async function roleIdOf(db: Db, role: RoleName): Promise<number | null> {
  const { data, error } = await db.from('roles').select('role_id, role_name').eq('role_name', role).maybeSingle()
  if (error || !data) return null
  return (data as RoleRow).role_id
}

// Returns 'ok' when departmentId is a department of the type the role needs (or none is needed and
// none was sent), otherwise a message for the Admin.
async function checkDepartment(db: Db, role: RoleName, departmentId: number | null): Promise<{ ok: true } | { ok: false; message: string }> {
  const need = DEPARTMENT_TYPE[role]
  if (!need) return departmentId === null ? { ok: true } : { ok: false, message: `The ${role} role has no department. Leave it empty.` }
  if (departmentId === null) return { ok: false, message: `Choose a ${need === 'Financial' ? 'finance' : 'academic'} department for the ${role} role.` }
  const { data, error } = await db.from('departments').select('department_type').eq('department_id', departmentId).maybeSingle()
  if (error) { logStep('read department', error); return { ok: false, message: GENERIC } }
  if (!data) return { ok: false, message: 'That department does not exist. Reload the page.' }
  if ((data as { department_type: string }).department_type !== need) {
    return { ok: false, message: `The ${role} role needs a${need === 'Academic' ? 'n' : ''} ${need} department.` }
  }
  return { ok: true }
}

// Sets (or clears) the department_staff row with the Admin's own session. No upsert: PostgREST's
// upsert would also write profile_id, which is not granted for UPDATE. Returns false on any error.
async function writeDepartment(db: Db, userId: string, departmentId: number | null): Promise<boolean> {
  const cur = await db.from('department_staff').select('department_id').eq('profile_id', userId).maybeSingle()
  if (cur.error) { logStep('read department_staff', cur.error); return false }
  const existing = (cur.data as { department_id: number } | null)?.department_id ?? null
  if (existing === departmentId) return true
  if (departmentId === null) {
    const del = await db.from('department_staff').delete().eq('profile_id', userId)
    if (del.error) logStep('delete department_staff', del.error)
    return !del.error
  }
  if (existing === null) {
    const ins = await db.from('department_staff').insert({ profile_id: userId, department_id: departmentId })
    if (ins.error) logStep('insert department_staff', ins.error)
    return !ins.error
  }
  const upd = await db.from('department_staff').update({ department_id: departmentId }).eq('profile_id', userId)
  if (upd.error) logStep('update department_staff', upd.error)
  return !upd.error
}

async function readDepartmentOf(db: Db, userId: string): Promise<number | null> {
  const { data } = await db.from('department_staff').select('department_id').eq('profile_id', userId).maybeSingle()
  return (data as { department_id: number } | null)?.department_id ?? null
}

async function currentRoleOf(db: Db, userId: string): Promise<RoleName | null> {
  const { data, error } = await db.from('profiles').select('roles(role_name)').eq('profile_id', userId).maybeSingle()
  if (error || !data) return null
  const roles = (data as { roles: { role_name: string } | { role_name: string }[] | null }).roles
  const name = Array.isArray(roles) ? roles[0]?.role_name : roles?.role_name
  return isRoleName(name) ? name : null
}

// Best-effort undo of a half-created staff account, in foreign-key order. False if anything is left.
async function undoAccount(admin: Db, userId: string): Promise<boolean> {
  let clean = true
  try {
    const p = await admin.from('profiles').delete().eq('profile_id', userId)
    if (p.error) clean = false
    const u = await admin.auth.admin.deleteUser(userId)
    if (u.error) clean = false
  } catch {
    clean = false
  }
  return clean
}

// A NEW one-time set-password link, emailed to the staff member. The link must belong to this very
// account. Returns false when the link or the email failed; nothing is undone.
async function sendInvite(admin: Db, userId: string, email: string, firstName: string, role: RoleName): Promise<boolean> {
  try {
    const site = await siteUrl()
    if (!site) return false
    const gen = await admin.auth.admin.generateLink({ type: 'recovery', email })
    const hashed = gen.data?.properties?.hashed_token
    if (gen.error || !hashed || gen.data?.user?.id !== userId) return false
    const link = `${site}/auth/confirm?token_hash=${encodeURIComponent(hashed)}&type=recovery`
    await sendMail({ to: email, ...staffWelcomeEmail(firstName, role, link) })
    return true
  } catch {
    return false
  }
}

function revalidate() {
  revalidatePath('/admin', 'layout')
}

// Creates a staff account (Registrar, Cashier, Department or Admin; students come from accepted
// applications) and emails a one-time set-password link.
export async function createStaffAccount(_prev: AdminUserActionState, formData: FormData): Promise<AdminUserActionState> {
  void _prev
  const firstName = readName(formData, 'firstName')
  const lastName = readName(formData, 'lastName')
  const role = readRole(formData)
  const email = String(formData.get('email') ?? '').trim().toLowerCase()
  const departmentId = readDepartmentId(formData)
  if (!firstName || !lastName) return fail(`Enter a first and a last name (up to ${MAX_NAME} characters each).`)
  if (!EMAIL_RE.test(email) || email.length > MAX_EMAIL) return fail('Enter a valid email address.')
  if (!role || role === 'Student') return fail('Choose a staff role. Student accounts are created from accepted applications.')

  let result: AdminUserActionState
  try {
    const ctx = await getAdminClientFor('Admin').catch(() => undefined)
    if (ctx === undefined) return fail(NOT_CONFIGURED)
    if (ctx === null) return fail(SESSION_ENDED)
    const db = (await createClient()) as unknown as Db

    const dept = await checkDepartment(db, role, departmentId)
    if (!dept.ok) return fail(dept.message)

    const inUse = await ctx.admin.from('profiles').select('profile_id').ilike('email', email).limit(1)
    if (inUse.error) { logStep('check email in profiles', inUse.error); return fail(GENERIC) }
    if ((inUse.data ?? []).length > 0) return fail(EMAIL_IN_USE)

    const roleId = await roleIdOf(ctx.admin, role)
    if (roleId === null) { logStep('read role', { message: 'role not found' }); return fail(GENERIC) }

    const created = await ctx.admin.auth.admin.createUser({ email, email_confirm: true, password: throwawayPassword() })
    const userId = created.data?.user?.id
    if (created.error || !userId) {
      logStep('create auth user', created.error ?? { message: 'no user returned' })
      return fail(created.error?.status === 422 ? EMAIL_IN_USE : GENERIC)
    }

    const undo = async (message: string): Promise<AdminUserActionState> =>
      fail((await undoAccount(ctx.admin, userId)) ? message : `Account setup stopped halfway and could not be fully undone. Ask the site owner to check ${email} before retrying.`)

    const prof = await ctx.admin.from('profiles').insert({
      profile_id: userId, role_id: roleId, first_name: firstName, last_name: lastName, email, is_active: true,
    })
    if (prof.error) { logStep('insert profile', prof.error); return undo(prof.error.code === '23505' ? EMAIL_IN_USE : GENERIC) }

    if (departmentId !== null && !(await writeDepartment(db, userId, departmentId))) return undo(GENERIC)

    const sent = await sendInvite(ctx.admin, userId, email, firstName, role)
    result = sent
      ? { status: 'success', message: `The ${role} account for ${email} is ready. The set-password email was sent.` }
      : { status: 'warning', message: `The account for ${email} was created but the email failed: use "Resend invite".` }
  } catch {
    result = fail(GENERIC)
  }
  revalidate()
  return result
}

// Edits name, role and department. Student accounts keep the Student role (and have no department);
// staff accounts cannot become Students. An Admin cannot take the Admin role from their own account.
export async function updateUserAccount(_prev: AdminUserActionState, formData: FormData): Promise<AdminUserActionState> {
  void _prev
  const userId = readUserId(formData)
  const firstName = readName(formData, 'firstName')
  const lastName = readName(formData, 'lastName')
  const role = readRole(formData)
  const departmentId = readDepartmentId(formData)
  if (!userId) return fail(NOT_FOUND)
  if (!firstName || !lastName) return fail(`Enter a first and a last name (up to ${MAX_NAME} characters each).`)
  if (!role) return fail('Choose a role.')

  let result: AdminUserActionState
  try {
    const ctx = await getAdminClientFor('Admin').catch(() => undefined)
    if (ctx === undefined) return fail(NOT_CONFIGURED)
    if (ctx === null) return fail(SESSION_ENDED)
    const db = (await createClient()) as unknown as Db

    const before = await currentRoleOf(db, userId)
    if (!before) return fail(NOT_FOUND)
    if ((before === 'Student') !== (role === 'Student')) return fail('A Student account keeps the Student role, and a staff account cannot become a Student.')
    if (userId === ctx.profile.id && role !== 'Admin') return fail('You cannot take the Admin role from your own account. Ask another Admin.')

    const dept = await checkDepartment(db, role, departmentId)
    if (!dept.ok) return fail(dept.message)

    const roleId = await roleIdOf(db, role)
    if (roleId === null) { logStep('read role', { message: 'role not found' }); return fail(GENERIC) }

    // Department first when the new role needs one (so a Department user is never left without), and
    // put it back if the profile update is then refused.
    const previousDept = await readDepartmentOf(db, userId)
    if (departmentId !== null && !(await writeDepartment(db, userId, departmentId))) return fail(GENERIC)

    const { data: updated, error } = await db
      .from('profiles')
      .update({ first_name: firstName, last_name: lastName, role_id: roleId })
      .eq('profile_id', userId)
      .select('profile_id')
    if (error || !updated || updated.length === 0) {
      if (error) logStep('update profile', error)
      if (departmentId !== null) await writeDepartment(db, userId, previousDept)
      return fail(error ? friendly(error) : NOT_ALLOWED)
    }

    // A role without a department: remove the old assignment only after the profile change worked.
    if (departmentId === null && previousDept !== null && !(await writeDepartment(db, userId, null))) {
      result = { status: 'warning', message: 'The account was saved but the old department assignment could not be removed. Save again.' }
    } else {
      result = { status: 'success', message: 'The account was saved.' }
    }
  } catch {
    result = fail(GENERIC)
  }
  revalidate()
  return result
}

// Deactivates or reactivates an account. Database first (is_active, which also cuts the person off
// from every RLS-protected row at once and fires the last-admin trigger), then Supabase Auth (ban or
// unban, so the person cannot sign in or refresh a session). Users are deactivated, never deleted.
export async function setUserActive(_prev: AdminUserActionState, formData: FormData): Promise<AdminUserActionState> {
  void _prev
  const userId = readUserId(formData)
  const flag = String(formData.get('active') ?? '').trim()
  if (!userId) return fail(NOT_FOUND)
  if (flag !== 'true' && flag !== 'false') return fail('That change is not allowed. Reload the page.')
  const active = flag === 'true'

  let result: AdminUserActionState
  try {
    const ctx = await getAdminClientFor('Admin').catch(() => undefined)
    if (ctx === undefined) return fail(NOT_CONFIGURED)
    if (ctx === null) return fail(SESSION_ENDED)
    if (!active && userId === ctx.profile.id) return fail('You cannot deactivate your own account. Ask another Admin.')
    const db = (await createClient()) as unknown as Db

    const { data: updated, error } = await db.from('profiles').update({ is_active: active }).eq('profile_id', userId).select('profile_id')
    if (error) { logStep('update is_active', error); return fail(friendly(error)) }
    if (!updated || updated.length === 0) return fail(NOT_FOUND)

    const ban = await ctx.admin.auth.admin.updateUserById(userId, { ban_duration: active ? 'none' : BAN_FOREVER })
    if (ban.error) {
      logStep(active ? 'unban auth user' : 'ban auth user', ban.error)
      result = {
        status: 'warning',
        message: active
          ? 'The account is active again but sign-in could not be unblocked. Try again.'
          : 'The account is deactivated and has no access, but its sign-in could not be blocked. Try again.',
      }
    } else {
      result = { status: 'success', message: active ? 'The account is active again.' : 'The account is deactivated.' }
    }
  } catch {
    result = fail(GENERIC)
  }
  revalidate()
  return result
}

// Sends a NEW set-password link to a staff account (the first email failed, or the link expired).
export async function resendStaffInvite(_prev: AdminUserActionState, formData: FormData): Promise<AdminUserActionState> {
  void _prev
  const userId = readUserId(formData)
  if (!userId) return fail(NOT_FOUND)
  try {
    const ctx = await getAdminClientFor('Admin').catch(() => undefined)
    if (ctx === undefined) return fail(NOT_CONFIGURED)
    if (ctx === null) return fail(SESSION_ENDED)
    const db = (await createClient()) as unknown as Db

    const { data, error } = await db.from('profiles').select('first_name, email, is_active, roles(role_name)').eq('profile_id', userId).maybeSingle()
    if (error || !data) return fail(NOT_FOUND)
    const row = data as { first_name: string; email: string; is_active: boolean; roles: { role_name: string } | { role_name: string }[] | null }
    const roleName = Array.isArray(row.roles) ? row.roles[0]?.role_name : row.roles?.role_name
    if (!isRoleName(roleName) || roleName === 'Student') return fail('Invites are only for staff accounts. A student uses the link from the acceptance email.')
    if (!row.is_active) return fail('This account is deactivated. Reactivate it first.')

    const sent = await sendInvite(ctx.admin, userId, row.email, row.first_name, roleName)
    return sent
      ? { status: 'success', message: `A new set-password email was sent to ${row.email}.` }
      : fail('The email could not be sent. Please try again in a few minutes.')
  } catch {
    return fail(GENERIC)
  }
}
