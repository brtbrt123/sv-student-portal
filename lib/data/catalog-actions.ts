'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { getCurrentProfile } from '@/lib/auth/session'
import { catalogErrorMessage, CATALOG_GENERIC } from '@/lib/data/catalog-errors'
import { parseDepartmentType, parseId, validateDepartment, validateProgram, validateSection, validateSubject, validateTerm } from '@/lib/data/catalog-validate'

// Server Actions for the Admin's Academic setup screen. They run with the signed-in user's own session:
// the database (RLS, column grants, check constraints) is the final gate; the checks here only give
// friendly messages. There is no delete: catalog rows are referenced elsewhere, so they are retired, never
// removed. The link columns (department, subject, term) are set when a row is created and cannot change.

export type CatalogActionState = { status: 'idle' | 'success' | 'error'; message: string }

const SESSION_ENDED = 'Your session has ended. Please sign in again.'
const NOT_FOUND = 'That record was not found or was not changed. Reload the page.'

const fail = (message: string): CatalogActionState => ({ status: 'error', message })
const ok = (message: string): CatalogActionState => {
  revalidatePath('/admin', 'layout')
  revalidatePath('/student', 'layout')
  revalidatePath('/registrar', 'layout')
  return { status: 'success', message }
}

async function adminClient() {
  const profile = await getCurrentProfile()
  if (!profile || profile.role !== 'Admin') return null
  return createClient()
}

const field = (formData: FormData, name: string) => formData.get(name)

export async function createTerm(_prev: CatalogActionState, formData: FormData): Promise<CatalogActionState> {
  void _prev
  const v = validateTerm({
    schoolYear: field(formData, 'schoolYear'),
    semester: field(formData, 'semester'),
    startDate: field(formData, 'startDate'),
    endDate: field(formData, 'endDate'),
  })
  if (!v.ok) return fail(v.message)
  try {
    const supabase = await adminClient()
    if (!supabase) return fail(SESSION_ENDED)
    // A new term is never current: use "Make current" so the old one is cleared first.
    const { error } = await supabase.from('terms').insert({
      school_year: v.value.schoolYear,
      semester: v.value.semester,
      start_date: v.value.startDate,
      end_date: v.value.endDate,
      is_current: false,
    })
    if (error) return fail(catalogErrorMessage(error.code, error.message))
  } catch {
    return fail(CATALOG_GENERIC)
  }
  return ok('Term added.')
}

export async function updateTerm(_prev: CatalogActionState, formData: FormData): Promise<CatalogActionState> {
  void _prev
  const id = parseId(field(formData, 'termId'))
  if (!id) return fail(NOT_FOUND)
  const v = validateTerm({
    schoolYear: field(formData, 'schoolYear'),
    semester: field(formData, 'semester'),
    startDate: field(formData, 'startDate'),
    endDate: field(formData, 'endDate'),
  })
  if (!v.ok) return fail(v.message)
  try {
    const supabase = await adminClient()
    if (!supabase) return fail(SESSION_ENDED)
    const { data, error } = await supabase
      .from('terms')
      .update({
        school_year: v.value.schoolYear,
        semester: v.value.semester,
        start_date: v.value.startDate,
        end_date: v.value.endDate,
      })
      .eq('term_id', id)
      .select('term_id')
    if (error) return fail(catalogErrorMessage(error.code, error.message))
    if (!data || data.length === 0) return fail(NOT_FOUND)
  } catch {
    return fail(CATALOG_GENERIC)
  }
  return ok('Term saved.')
}

// Makes one term the current term. Two statements, in this order, because the database allows only one
// current term at a time: (1) clear the old current term, (2) set the new one. If (2) fails after (1)
// worked, the old term is put back, and the message says what happened.
export async function setCurrentTerm(_prev: CatalogActionState, formData: FormData): Promise<CatalogActionState> {
  void _prev
  const id = parseId(field(formData, 'termId'))
  if (!id) return fail(NOT_FOUND)
  try {
    const supabase = await adminClient()
    if (!supabase) return fail(SESSION_ENDED)

    const { data: currentRows, error: readError } = await supabase.from('terms').select('term_id').eq('is_current', true)
    if (readError) return fail(catalogErrorMessage(readError.code, readError.message))
    const oldIds = (currentRows ?? []).map((r) => r.term_id)
    if (oldIds.length === 1 && oldIds[0] === id) return { status: 'success', message: 'That term is already the current term.' }

    // Statement 1: clear the old current term (nothing to clear when none is current).
    if (oldIds.length > 0) {
      const { error: clearError } = await supabase.from('terms').update({ is_current: false }).in('term_id', oldIds)
      if (clearError) {
        return fail(`The current term was not changed. ${catalogErrorMessage(clearError.code, clearError.message)}`)
      }
    }

    // Statement 2: set the new current term.
    const { data: setRows, error: setError } = await supabase
      .from('terms')
      .update({ is_current: true })
      .eq('term_id', id)
      .select('term_id')
    if (setError || !setRows || setRows.length === 0) {
      const reason = setError ? catalogErrorMessage(setError.code, setError.message) : NOT_FOUND
      if (oldIds.length === 0) return fail(`The current term was not changed. ${reason}`)
      // Put the old current term back.
      const { error: restoreError } = await supabase.from('terms').update({ is_current: true }).in('term_id', oldIds)
      revalidatePath('/admin', 'layout')
      if (restoreError) {
        return fail(
          `The old current term was cleared, but the new one could not be set, and the old one could not be put back, so no term is current now. Students cannot enrol until you choose a current term again. ${reason}`
        )
      }
      return fail(`The new current term could not be set, so the old current term was put back. ${reason}`)
    }
  } catch {
    return fail(CATALOG_GENERIC)
  }
  return ok('Current term changed.')
}

export async function createDepartment(_prev: CatalogActionState, formData: FormData): Promise<CatalogActionState> {
  void _prev
  const type = parseDepartmentType(field(formData, 'departmentType'))
  if (!type) return fail('Choose the type of the department: Academic or Financial.')
  const v = validateDepartment({ code: field(formData, 'code'), name: field(formData, 'name') })
  if (!v.ok) return fail(v.message)
  try {
    const supabase = await adminClient()
    if (!supabase) return fail(SESSION_ENDED)
    const { error } = await supabase
      .from('departments')
      .insert({ code: v.value.code, name: v.value.name, department_type: type })
    if (error) return fail(catalogErrorMessage(error.code, error.message))
  } catch {
    return fail(CATALOG_GENERIC)
  }
  return ok('Department added.')
}

// The type of a department is not sent: the database does not let it change after the department is created.
export async function updateDepartment(_prev: CatalogActionState, formData: FormData): Promise<CatalogActionState> {
  void _prev
  const id = parseId(field(formData, 'departmentId'))
  if (!id) return fail(NOT_FOUND)
  const v = validateDepartment({ code: field(formData, 'code'), name: field(formData, 'name') })
  if (!v.ok) return fail(v.message)
  try {
    const supabase = await adminClient()
    if (!supabase) return fail(SESSION_ENDED)
    const { data, error } = await supabase
      .from('departments')
      .update({ code: v.value.code, name: v.value.name })
      .eq('department_id', id)
      .select('department_id')
    if (error) return fail(catalogErrorMessage(error.code, error.message))
    if (!data || data.length === 0) return fail(NOT_FOUND)
  } catch {
    return fail(CATALOG_GENERIC)
  }
  return ok('Department saved.')
}

export async function createProgram(_prev: CatalogActionState, formData: FormData): Promise<CatalogActionState> {
  void _prev
  const departmentId = parseId(field(formData, 'departmentId'))
  if (!departmentId) return fail('Choose the department of the program.')
  const v = validateProgram({ code: field(formData, 'code'), name: field(formData, 'name') })
  if (!v.ok) return fail(v.message)
  try {
    const supabase = await adminClient()
    if (!supabase) return fail(SESSION_ENDED)
    const { error } = await supabase
      .from('programs')
      .insert({ department_id: departmentId, code: v.value.code, name: v.value.name })
    if (error) return fail(catalogErrorMessage(error.code, error.message))
  } catch {
    return fail(CATALOG_GENERIC)
  }
  return ok('Program added.')
}

export async function updateProgram(_prev: CatalogActionState, formData: FormData): Promise<CatalogActionState> {
  void _prev
  const id = parseId(field(formData, 'programId'))
  if (!id) return fail(NOT_FOUND)
  const v = validateProgram({ code: field(formData, 'code'), name: field(formData, 'name') })
  if (!v.ok) return fail(v.message)
  try {
    const supabase = await adminClient()
    if (!supabase) return fail(SESSION_ENDED)
    const { data, error } = await supabase
      .from('programs')
      .update({ code: v.value.code, name: v.value.name })
      .eq('program_id', id)
      .select('program_id')
    if (error) return fail(catalogErrorMessage(error.code, error.message))
    if (!data || data.length === 0) return fail(NOT_FOUND)
  } catch {
    return fail(CATALOG_GENERIC)
  }
  return ok('Program saved.')
}

export async function createSubject(_prev: CatalogActionState, formData: FormData): Promise<CatalogActionState> {
  void _prev
  const departmentId = parseId(field(formData, 'departmentId'))
  if (!departmentId) return fail('Choose the department of the subject.')
  const v = validateSubject({ code: field(formData, 'code'), title: field(formData, 'title'), units: field(formData, 'units') })
  if (!v.ok) return fail(v.message)
  try {
    const supabase = await adminClient()
    if (!supabase) return fail(SESSION_ENDED)
    const { error } = await supabase
      .from('subjects')
      .insert({ department_id: departmentId, code: v.value.code, title: v.value.title, units: v.value.units })
    if (error) return fail(catalogErrorMessage(error.code, error.message))
  } catch {
    return fail(CATALOG_GENERIC)
  }
  return ok('Subject added.')
}

export async function updateSubject(_prev: CatalogActionState, formData: FormData): Promise<CatalogActionState> {
  void _prev
  const id = parseId(field(formData, 'subjectId'))
  if (!id) return fail(NOT_FOUND)
  const v = validateSubject({ code: field(formData, 'code'), title: field(formData, 'title'), units: field(formData, 'units') })
  if (!v.ok) return fail(v.message)
  try {
    const supabase = await adminClient()
    if (!supabase) return fail(SESSION_ENDED)
    const { data, error } = await supabase
      .from('subjects')
      .update({ code: v.value.code, title: v.value.title, units: v.value.units })
      .eq('subject_id', id)
      .select('subject_id')
    if (error) return fail(catalogErrorMessage(error.code, error.message))
    if (!data || data.length === 0) return fail(NOT_FOUND)
  } catch {
    return fail(CATALOG_GENERIC)
  }
  return ok('Subject saved.')
}

export async function createSection(_prev: CatalogActionState, formData: FormData): Promise<CatalogActionState> {
  void _prev
  const subjectId = parseId(field(formData, 'subjectId'))
  if (!subjectId) return fail('Choose the subject of the section.')
  const termId = parseId(field(formData, 'termId'))
  if (!termId) return fail('Choose the term of the section.')
  const v = validateSection({
    sectionCode: field(formData, 'sectionCode'),
    schedule: field(formData, 'schedule'),
    capacity: field(formData, 'capacity'),
  })
  if (!v.ok) return fail(v.message)
  try {
    const supabase = await adminClient()
    if (!supabase) return fail(SESSION_ENDED)
    const { error } = await supabase.from('sections').insert({
      subject_id: subjectId,
      term_id: termId,
      section_code: v.value.sectionCode,
      schedule: v.value.schedule,
      capacity: v.value.capacity,
    })
    if (error) return fail(catalogErrorMessage(error.code, error.message))
  } catch {
    return fail(CATALOG_GENERIC)
  }
  return ok('Section added.')
}

// Only the section code, schedule and capacity can change; the subject and term are fixed at creation.
export async function updateSection(_prev: CatalogActionState, formData: FormData): Promise<CatalogActionState> {
  void _prev
  const id = parseId(field(formData, 'sectionId'))
  if (!id) return fail(NOT_FOUND)
  const v = validateSection({
    sectionCode: field(formData, 'sectionCode'),
    schedule: field(formData, 'schedule'),
    capacity: field(formData, 'capacity'),
  })
  if (!v.ok) return fail(v.message)
  try {
    const supabase = await adminClient()
    if (!supabase) return fail(SESSION_ENDED)
    const { data, error } = await supabase
      .from('sections')
      .update({ section_code: v.value.sectionCode, schedule: v.value.schedule, capacity: v.value.capacity })
      .eq('section_id', id)
      .select('section_id')
    if (error) return fail(catalogErrorMessage(error.code, error.message))
    if (!data || data.length === 0) return fail(NOT_FOUND)
  } catch {
    return fail(CATALOG_GENERIC)
  }
  return ok('Section saved.')
}
