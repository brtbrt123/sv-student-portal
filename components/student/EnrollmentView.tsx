import { Section, StatusBadge, type Hue } from '@/components/ui'
import type { ChosenSection, EnrollmentSectionInfo, StudentEnrollment } from '@/lib/data/enrollment'
import EnrollmentAddSectionForm from './EnrollmentAddSectionForm'
import EnrollmentRemoveButton from './EnrollmentRemoveButton'
import EnrollmentSubmitForm from './EnrollmentSubmitForm'
import { formatShortDate } from './format'
import { ResponsiveTable, type Column } from './ResponsiveTable'
import { StatGrid } from './StatGrid'

const STATUS_HUE: Record<string, Hue> = { Approved: 'teal', Pending: 'amber', Rejected: 'rose' }
const STATUS_HINT: Record<string, string> = {
  Approved: 'confirmed by the Registrar',
  Pending: 'waiting for the Registrar',
  Rejected: 'not approved',
}

// Live: the student's enrollment for the current term, its sections (removable while Pending), the
// section picker and the submit form. The Registrar approves or rejects. Server component; the forms
// are client components that call server actions.
export default function EnrollmentView({
  termLabel,
  enrollment,
  chosen,
  available,
  setByProgram,
}: {
  termLabel: string
  enrollment: StudentEnrollment | null
  chosen: ChosenSection[]
  available: EnrollmentSectionInfo[]
  /** A new student's subjects are set by their program: no picking or removing; the Registrar drops one on request. */
  setByProgram: boolean
}) {
  const pending = enrollment?.status === 'Pending'
  const units = chosen.reduce((sum, s) => sum + s.units, 0)

  const columns: Column<ChosenSection>[] = [
    { key: 'code', header: 'Code', primary: true, cell: (s) => s.subjectCode },
    { key: 'subject', header: 'Subject', cell: (s) => s.subjectTitle },
    { key: 'units', header: 'Units', className: 'w-20', cell: (s) => s.units },
    { key: 'section', header: 'Section', cell: (s) => s.sectionCode },
    { key: 'schedule', header: 'Schedule', cell: (s) => s.schedule ?? 'To be announced' },
    ...(pending && enrollment && !setByProgram
      ? [
          {
            key: 'remove',
            header: 'Remove',
            cell: (s: ChosenSection) => (
              <EnrollmentRemoveButton
                enrollmentId={enrollment.id}
                itemId={s.itemId}
                label={`${s.subjectCode} section ${s.sectionCode}`}
              />
            ),
          },
        ]
      : []),
  ]

  return (
    <div className="flex flex-col gap-8">
      <StatGrid
        stats={[
          {
            label: 'Status',
            value: enrollment?.status ?? 'None',
            hint: enrollment ? (STATUS_HINT[enrollment.status] ?? 'this term') : 'not enrolled yet',
            hue: enrollment ? STATUS_HUE[enrollment.status] : undefined,
          },
          { label: 'Subjects', value: chosen.length, hint: 'this term' },
          { label: 'Units', value: units, hint: 'total units' },
          enrollment
            ? enrollment.reviewedAt
              ? { label: 'Reviewed', value: formatShortDate(enrollment.reviewedAt), hint: 'by the Registrar' }
              : { label: 'Submitted', value: formatShortDate(enrollment.submittedAt), hint: `Year ${enrollment.yearLevel}` }
            : { label: 'Submitted', value: '-', hint: 'nothing submitted' },
        ]}
      />

      {enrollment?.status === 'Approved' && (
        <div role="status" className="rounded-lg border border-edge bg-card px-4 py-4 text-sm lg:px-5">
          <p className="flex flex-wrap items-center gap-2 font-semibold">
            <StatusBadge status="Approved" /> You are enrolled for {termLabel}.
          </p>
          <p className="mt-2 text-muted">
            The Registrar approved your enrollment on {formatShortDate(enrollment.reviewedAt)}. Your subjects are listed
            below and can no longer be changed.
          </p>
          {enrollment.remarks && <p className="mt-2">Registrar remarks: {enrollment.remarks}</p>}
        </div>
      )}

      {enrollment?.status === 'Rejected' && (
        <div role="status" className="rounded-lg border border-danger/30 bg-danger-soft px-4 py-4 text-sm lg:px-5">
          <p className="flex flex-wrap items-center gap-2 font-semibold">
            <StatusBadge status="Rejected" /> Your enrollment for {termLabel} was not approved.
          </p>
          <p className="mt-2">Reviewed on {formatShortDate(enrollment.reviewedAt)}.</p>
          <p className="mt-2">Registrar remarks: {enrollment.remarks ?? 'No remarks were given.'}</p>
          <p className="mt-2 text-muted">A rejected enrollment is final. Please see the Registrar for the next step.</p>
        </div>
      )}

      {enrollment === null && setByProgram ? (
        <Section title="Your enrollment" description={termLabel}>
          <p className="rounded-lg border border-dashed border-border px-4 py-6 text-sm text-muted">
            Your first-year subjects are set by your program and are added when the Registrar accepts your application. They are
            not here yet. Please ask the Registrar to set up your enrollment.
          </p>
        </Section>
      ) : enrollment === null ? (
        <Section title="Submit enrollment" description={`${termLabel}. New enrollments start as Pending until the Registrar reviews them.`}>
          <EnrollmentSubmitForm termLabel={termLabel} />
        </Section>
      ) : (
        <>
          <Section title="Enrolled subjects" description={`${termLabel} · Year ${enrollment.yearLevel}`}>
            <ResponsiveTable
              columns={columns}
              rows={chosen}
              rowKey={(s) => s.itemId}
              caption={`Enrolled subjects, ${termLabel}`}
              empty={pending && !setByProgram ? 'No subjects yet. Add a section with the form below.' : 'No subjects were added to this enrollment.'}
            />
          </Section>

          {pending && setByProgram && (
            <Section title="Dropping a subject" description="Your subjects are set by your program.">
              <p className="rounded-lg border border-edge bg-card px-4 py-4 text-sm text-muted">
                You do not need to pick subjects. If you need to drop one, tell the Registrar at the window and they will remove
                it for you while your enrollment is Pending.
              </p>
            </Section>
          )}

          {pending && !setByProgram && (
            <Section
              title="Add a section"
              description="Sections can be added or removed only while the enrollment is Pending. The Registrar checks for a free seat when approving."
            >
              {available.length === 0 ? (
                <p className="rounded-lg border border-dashed border-border px-4 py-6 text-sm text-muted">
                  {chosen.length === 0
                    ? 'No sections are open for this term yet. Check back later.'
                    : 'You have added every section that is open for this term.'}
                </p>
              ) : (
                // Remounts after each change so the select shows the sections that are left.
                <EnrollmentAddSectionForm key={chosen.length} enrollmentId={enrollment.id} sections={available} />
              )}
            </Section>
          )}
        </>
      )}
    </div>
  )
}
