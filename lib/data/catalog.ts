import { createClient } from '@/lib/supabase/server'

// Server-side read of the academic catalog for the Admin's Academic setup screen. Runs with the signed-in
// user's own session; RLS lets every signed-in user read the catalog and only the Admin write it.
// Import from Server Components and Server Actions only.

export type CatalogDepartment = { id: number; code: string; name: string; type: string }
export type CatalogTerm = {
  id: number
  schoolYear: string
  semester: string
  startDate: string
  endDate: string
  isCurrent: boolean
  label: string
}
export type CatalogProgram = { id: number; code: string; name: string; departmentId: number; departmentName: string }
export type CatalogSubject = {
  id: number
  code: string
  title: string
  units: number
  departmentId: number
  departmentName: string
}
export type CatalogSection = {
  id: number
  sectionCode: string
  subjectId: number
  subjectCode: string
  subjectTitle: string
  termId: number
  termLabel: string
  schedule: string
  capacity: number
}

export type CatalogState =
  | {
      kind: 'ready'
      departments: CatalogDepartment[]
      terms: CatalogTerm[]
      programs: CatalogProgram[]
      subjects: CatalogSubject[]
      sections: CatalogSection[]
      currentTermId: number | null
    }
  | { kind: 'error' }

// Everything the screen needs, in one pass. Never throws.
export async function getCatalogState(): Promise<CatalogState> {
  try {
    const supabase = await createClient()
    const [depRes, termRes, progRes, subRes, secRes] = await Promise.all([
      supabase.from('departments').select('department_id, code, name, department_type').order('code', { ascending: true }),
      supabase
        .from('terms')
        .select('term_id, school_year, semester, start_date, end_date, is_current')
        .order('start_date', { ascending: false }),
      supabase.from('programs').select('program_id, department_id, code, name').order('code', { ascending: true }),
      supabase.from('subjects').select('subject_id, department_id, code, title, units').order('code', { ascending: true }),
      supabase
        .from('sections')
        .select('section_id, subject_id, term_id, section_code, schedule, capacity')
        .order('section_code', { ascending: true }),
    ])
    if (depRes.error || termRes.error || progRes.error || subRes.error || secRes.error) return { kind: 'error' }

    const departments: CatalogDepartment[] = (depRes.data ?? []).map((d) => ({
      id: d.department_id,
      code: d.code,
      name: d.name,
      type: d.department_type,
    }))
    const deptName = new Map(departments.map((d) => [d.id, d.name]))

    const terms: CatalogTerm[] = (termRes.data ?? []).map((t) => ({
      id: t.term_id,
      schoolYear: t.school_year,
      semester: t.semester,
      startDate: t.start_date,
      endDate: t.end_date,
      isCurrent: t.is_current,
      label: `${t.semester} ${t.school_year}`,
    }))
    const termLabel = new Map(terms.map((t) => [t.id, t.label]))

    const programs: CatalogProgram[] = (progRes.data ?? []).map((p) => ({
      id: p.program_id,
      code: p.code,
      name: p.name,
      departmentId: p.department_id,
      departmentName: deptName.get(p.department_id) ?? '-',
    }))

    const subjects: CatalogSubject[] = (subRes.data ?? []).map((s) => ({
      id: s.subject_id,
      code: s.code,
      title: s.title,
      units: s.units,
      departmentId: s.department_id,
      departmentName: deptName.get(s.department_id) ?? '-',
    }))
    const subjectById = new Map(subjects.map((s) => [s.id, s]))

    const sections: CatalogSection[] = (secRes.data ?? []).map((s) => ({
      id: s.section_id,
      sectionCode: s.section_code,
      subjectId: s.subject_id,
      subjectCode: subjectById.get(s.subject_id)?.code ?? '-',
      subjectTitle: subjectById.get(s.subject_id)?.title ?? 'Subject',
      termId: s.term_id,
      termLabel: termLabel.get(s.term_id) ?? 'Term',
      schedule: s.schedule ?? '',
      capacity: s.capacity,
    }))

    return {
      kind: 'ready',
      departments,
      terms,
      programs,
      subjects,
      sections,
      currentTermId: terms.find((t) => t.isCurrent)?.id ?? null,
    }
  } catch {
    return { kind: 'error' }
  }
}
