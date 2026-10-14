import DashboardShell from '@/components/layout/DashboardShell'
import QueuePass from '@/components/student/QueuePass'
import { EmptyState } from '@/components/ui'
import { requireRole } from '@/lib/auth/session'
import { getStudentDocumentsState } from '@/lib/data/documents'
import { getStudentEnrollmentState } from '@/lib/data/enrollment'
import { expireHolds, getLastServedAt, getMyQueueStatus, type MyQueueStatus } from '@/lib/data/queue'
import { isActiveTicketStatus, needsNewNumber } from '@/lib/queue/line'

const inLine = (q: MyQueueStatus | null) => q?.hasTicket === true && isActiveTicketStatus(q.ticketStatus)

// The student's queue page: one pass per line at the Registrar window. A line shows its QR code only while
// there is a reason to go (an enrollment waiting for the Registrar, an open document request) or while the
// student already has a ticket in that line.
export default async function StudentQueuePage() {
  const profile = await requireRole('Student')
  await expireHolds() // a hold that ran out is closed (and the student told) before the status is read
  const [enrollment, documents, enrollmentQueue, documentsQueue, enrollmentServedAt, documentsServedAt] = await Promise.all([
    getStudentEnrollmentState(),
    getStudentDocumentsState(),
    getMyQueueStatus('Enrollment'),
    getMyQueueStatus('Documents'),
    getLastServedAt('Enrollment'),
    getLastServedAt('Documents'),
  ])

  // The code comes back only for something newer than the last time the student was served in that line (a
  // Cancelled or No-show ticket is not a service, so the same item still counts).
  const showEnrollment =
    inLine(enrollmentQueue) ||
    (enrollment.kind === 'ready' &&
      enrollment.enrollment?.status === 'Pending' &&
      needsNewNumber([enrollment.enrollment.submittedAt], enrollmentServedAt))
  const showDocuments =
    inLine(documentsQueue) ||
    (documents.kind === 'ready' &&
      needsNewNumber(
        documents.requests.filter((r) => ['Pending', 'Processing', 'Ready'].includes(r.status)).map((r) => r.processedAt ?? r.requestedAt),
        documentsServedAt
      ))
  const servedToday = enrollmentQueue?.ticketStatus === 'Done' || documentsQueue?.ticketStatus === 'Done'

  return (
    <DashboardShell profile={profile} title="Queue" subtitle="Your number for the Registrar window">
      <div className="flex flex-col gap-6">
        {showEnrollment && (
          <QueuePass
            service="Enrollment"
            status={enrollmentQueue}
            title="Enrollment line"
            intro="Please go to the school to finish your enrollment in person. Show this code at the Registrar's scanner to get your queue number, then follow the line from your phone."
          />
        )}
        {showDocuments && (
          <QueuePass
            service="Documents"
            status={documentsQueue}
            title="Document claim line"
            intro="When your document is ready, go to the school and show this code at the Registrar's scanner to get your queue number, then follow the line from your phone."
          />
        )}
        {!showEnrollment && !showDocuments && (
          <EmptyState title={servedToday ? 'You were served' : 'Nothing to queue for'}>
            {servedToday
              ? 'Your queue code appears here again when you submit a new request or enrollment.'
              : 'Your queue code appears here after you submit your enrollment or request a document.'}
          </EmptyState>
        )}
      </div>
    </DashboardShell>
  )
}
