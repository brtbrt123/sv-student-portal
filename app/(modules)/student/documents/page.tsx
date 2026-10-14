import DashboardShell from '@/components/layout/DashboardShell'
import DocumentRequestsView from '@/components/student/DocumentRequestsView'
import { JumpLink } from '@/components/student/PageActions'
import QueueNotice from '@/components/student/QueueNotice'
import { EmptyState } from '@/components/ui'
import { requireRole } from '@/lib/auth/session'
import { getStudentDocumentsState } from '@/lib/data/documents'
import { getMyQueueStatus } from '@/lib/data/queue'
import { isActiveTicketStatus } from '@/lib/queue/line'

const NOTICES: Record<string, string> = {
  requested: 'Request sent. It is listed below as Pending until the Registrar starts processing it.',
}

export default async function StudentDocumentsPage({
  searchParams,
}: {
  searchParams: Promise<{ [key: string]: string | string[] | undefined }>
}) {
  const profile = await requireRole('Student')
  const [state, queue] = await Promise.all([getStudentDocumentsState(), getMyQueueStatus('Documents')])
  const { notice } = await searchParams
  // The queue pass is for claiming at the Registrar: shown while the student has an open request (not yet
  // Released or Rejected) and for as long as they have a ticket in the line.
  const hasOpenRequest = state.kind === 'ready' && state.requests.some((r) => ['Pending', 'Processing', 'Ready'].includes(r.status))
  const inLine = queue?.hasTicket === true && isActiveTicketStatus(queue.ticketStatus)
  const showQueue = state.kind === 'ready' && (inLine || hasOpenRequest)
  const noticeText = typeof notice === 'string' ? NOTICES[notice] : undefined

  return (
    <DashboardShell
      profile={profile}
      title="Document requests"
      subtitle="Request records from the Registrar and track their status"
      actions={state.kind === 'ready' ? <JumpLink href="#new-request">New request</JumpLink> : undefined}
    >
      {noticeText && state.kind === 'ready' && (
        <p role="status" className="mb-4 rounded-md border border-edge bg-card px-4 py-3 text-sm text-foreground">
          {noticeText}
        </p>
      )}
      {showQueue && (
        <div className="mb-6">
          <QueueNotice status={queue} text="Show your code there to get a queue number, then follow the line from your phone." />
        </div>
      )}
      {state.kind === 'error' ? (
        <div role="alert">
          <EmptyState title="We could not load your document requests">
            Something went wrong on our side. Reload the page, and if it keeps happening, come back in a few minutes.
          </EmptyState>
        </div>
      ) : (
        <DocumentRequestsView documentTypes={state.types} requests={state.requests} />
      )}
    </DashboardShell>
  )
}
