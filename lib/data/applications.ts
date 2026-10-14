import type { SupabaseClient } from '@supabase/supabase-js'
import { createClient } from '@/lib/supabase/server'
import { formatStudentId } from '@/lib/auth/student-id'

// Server-side reads for the Registrar's applications screen. Every query runs with the signed-in
// user's own session (anon key + auth cookies), so Row Level Security does the isolation: the
// Registrar can read every application, other roles get nothing. No server-only key is used here.
// Import from Server Components and Server Actions only.
//
// public.applications is not in types/database.types.ts yet, so the session client is used untyped
// for that table (rows are mapped field by field below).

export type ApplicationStatus = 'Pending' | 'Accepted' | 'Rejected'

export const APPLICATION_STATUSES: readonly ApplicationStatus[] = ['Pending', 'Accepted', 'Rejected']

export type ApplicationItem = {
  /** application_id as text (works whether the column is a number or a uuid). */
  id: string
  firstName: string
  lastName: string
  name: string
  email: string
  mobile: string | null
  programCode: string
  programName: string
  status: ApplicationStatus
  submittedAt: string
  reviewedAt: string | null
  /** Name of the Registrar staff member who decided it (null when unknown or not decided). */
  reviewedByName: string | null
  remarks: string | null
  /** True once the student account exists (student_id set). */
  provisioned: boolean
  provisionedAt: string | null
  /** The student number, when provisioned and readable. */
  studentNumber: string | null
}

export type ApplicationsState = { kind: 'ready'; applications: ApplicationItem[] } | { kind: 'error' }

type ApplicationRow = {
  application_id: string | number
  first_name: string | null
  last_name: string | null
  email: string | null
  mobile: string | null
  program_id: number | null
  status: string
  submitted_at: string
  reviewed_by: string | null
  reviewed_at: string | null
  remarks: string | null
  student_id: string | null
  provisioned_at: string | null
}

export const APPLICATION_COLUMNS =
  'application_id, first_name, last_name, email, mobile, program_id, status, submitted_at, reviewed_by, reviewed_at, remarks, student_id, provisioned_at'

const toStatus = (s: string): ApplicationStatus =>
  (APPLICATION_STATUSES as readonly string[]).includes(s) ? (s as ApplicationStatus) : 'Pending'

const unique = <T,>(values: T[]): T[] => [...new Set(values)]

// Every application (Registrar only), oldest submission first. Program, student number and reviewer
// name are read separately; programs are core (the screen shows them), names and numbers are a
// convenience. Never throws.
export async function getApplicationsState(): Promise<ApplicationsState> {
  try {
    const supabase = (await createClient()) as unknown as SupabaseClient
    const appRes = await supabase
      .from('applications')
      .select(APPLICATION_COLUMNS)
      .order('submitted_at', { ascending: true })
      .order('application_id', { ascending: true })
    if (appRes.error) return { kind: 'error' }
    const rows = (appRes.data ?? []) as ApplicationRow[]

    const programIds = unique(rows.map((r) => r.program_id).filter((v): v is number => v !== null))
    const studentIds = unique(rows.map((r) => r.student_id).filter((v): v is string => v !== null))
    const reviewerIds = unique(rows.map((r) => r.reviewed_by).filter((v): v is string => v !== null))

    const [progRes, stuRes, profRes] = await Promise.all([
      programIds.length
        ? supabase.from('programs').select('program_id, code, name').in('program_id', programIds)
        : Promise.resolve({ data: [], error: null }),
      studentIds.length
        ? supabase.from('students').select('student_id, student_number').in('student_id', studentIds)
        : Promise.resolve({ data: [], error: null }),
      reviewerIds.length
        ? supabase.from('profiles').select('profile_id, first_name, last_name').in('profile_id', reviewerIds)
        : Promise.resolve({ data: [], error: null }),
    ])
    if (progRes.error) return { kind: 'error' }

    const programs = new Map(
      ((progRes.data ?? []) as { program_id: number; code: string; name: string }[]).map((p) => [p.program_id, p])
    )
    const numbers = new Map(
      (stuRes.error ? [] : ((stuRes.data ?? []) as { student_id: string; student_number: string }[])).map((s) => [
        s.student_id,
        formatStudentId(s.student_number),
      ])
    )
    const people = new Map(
      (profRes.error ? [] : ((profRes.data ?? []) as { profile_id: string; first_name: string; last_name: string }[])).map(
        (p) => [p.profile_id, `${p.first_name} ${p.last_name}`.trim()]
      )
    )

    const applications: ApplicationItem[] = rows.map((r) => {
      const program = r.program_id !== null ? programs.get(r.program_id) : undefined
      const firstName = r.first_name ?? ''
      const lastName = r.last_name ?? ''
      return {
        id: String(r.application_id),
        firstName,
        lastName,
        name: `${firstName} ${lastName}`.trim() || 'Applicant',
        email: r.email ?? '',
        mobile: r.mobile,
        programCode: program?.code ?? '-',
        programName: program?.name ?? 'Unknown program',
        status: toStatus(r.status),
        submittedAt: r.submitted_at,
        reviewedAt: r.reviewed_at,
        reviewedByName: r.reviewed_by ? (people.get(r.reviewed_by) ?? null) : null,
        remarks: r.remarks,
        provisioned: r.student_id !== null,
        provisionedAt: r.provisioned_at,
        studentNumber: r.student_id ? (numbers.get(r.student_id) ?? null) : null,
      }
    })
    return { kind: 'ready', applications }
  } catch {
    return { kind: 'error' }
  }
}
