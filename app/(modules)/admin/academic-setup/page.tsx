import DashboardShell from '@/components/layout/DashboardShell'
import TableCard from '@/components/admin/TableCard'
import { CatalogTerms } from '@/components/admin/CatalogTerms'
import { CatalogPrograms } from '@/components/admin/CatalogPrograms'
import { CatalogSubjects } from '@/components/admin/CatalogSubjects'
import { CatalogSections } from '@/components/admin/CatalogSections'
import { requireRole } from '@/lib/auth/session'
import { EmptyState, SummaryStrip, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui'
import { getCatalogState } from '@/lib/data/catalog'

export default async function AdminAcademicSetupPage() {
  const profile = await requireRole('Admin')
  const state = await getCatalogState()

  if (state.kind === 'error') {
    return (
      <DashboardShell profile={profile} title="Academic Setup" subtitle="Terms, programs, departments, subjects and sections">
        <EmptyState title="The academic setup could not be loaded">
          Something went wrong on our side. Reload the page in a few minutes.
        </EmptyState>
      </DashboardShell>
    )
  }

  const { terms, programs, subjects, sections, departments, currentTermId } = state
  const current = terms.find((t) => t.id === currentTermId) ?? null
  const currentSections = sections.filter((s) => s.termId === currentTermId).length

  return (
    <DashboardShell profile={profile} title="Academic Setup" subtitle="Terms, programs, departments, subjects and sections">
      <div className="flex flex-col gap-6">
        <SummaryStrip
          items={[
            { label: 'Current term', value: current ? current.label : 'None', hint: current ? `${current.startDate} to ${current.endDate}` : 'Choose one below', hue: current ? undefined : 'rose' },
            { label: 'Programs', value: programs.length },
            { label: 'Subjects', value: subjects.length },
            { label: 'Sections', value: currentSections, hint: 'in the current term' },
          ]}
        />

        {!current && (
          <p role="alert" className="rounded-lg border border-danger/30 bg-danger-soft px-4 py-3 text-sm text-danger">
            No term is current. Students cannot enrol until you choose a current term.
          </p>
        )}

        <CatalogTerms terms={terms} />
        <CatalogPrograms programs={programs} departments={departments} />
        <CatalogSubjects subjects={subjects} departments={departments} />
        <CatalogSections sections={sections} subjects={subjects} terms={terms} currentTermId={currentTermId} />

        <TableCard title="Departments" description="Read only. Departments are changed by the database team." minWidth="min-w-[480px]">
          <TableHeader>
            <TableRow className="hover:bg-transparent">
              {['Code', 'Name', 'Type'].map((c) => (
                <TableHead key={c} scope="col">
                  {c}
                </TableHead>
              ))}
            </TableRow>
          </TableHeader>
          <TableBody>
            {departments.map((d) => (
              <TableRow key={d.id}>
                <TableCell>{d.code}</TableCell>
                <TableCell className="font-normal text-muted">{d.name}</TableCell>
                <TableCell className="font-normal text-muted">{d.type}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </TableCard>
      </div>
    </DashboardShell>
  )
}
