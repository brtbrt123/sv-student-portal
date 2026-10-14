import DashboardShell from '@/components/layout/DashboardShell'
import { AutoRefresh } from '@/components/queue/AutoRefresh'
import QueueDesk from '@/components/registrar/QueueDesk'
import QueueScanner from '@/components/registrar/QueueScanner'
import TicketQueue from '@/components/registrar/TicketQueue'
import { EmptyState } from '@/components/ui'
import { requireRole } from '@/lib/auth/session'
import { getStaffQueue } from '@/lib/data/queue'

// The enrollment line at the Registrar window: scan a student's rotating QR code to issue a ticket, call
// the next number, finish it. Students see their own number and the number being served on their
// Enrollment page.
export default async function RegistrarQueuePage() {
  const profile = await requireRole('Registrar')
  const tickets = await getStaffQueue('Enrollment')

  return (
    <DashboardShell profile={profile} title="Queue" subtitle="Registrar Office · enrollment line for today">
      <AutoRefresh everySeconds={5} />
      {tickets === null ? (
        <div role="alert">
          <EmptyState title="We could not load the queue">
            Something went wrong on our side. Reload the page, and if it keeps happening, come back in a few minutes.
          </EmptyState>
        </div>
      ) : (
        <QueueDesk
          scanner={<QueueScanner service="Enrollment" />}
          line={<TicketQueue service="Enrollment" tickets={tickets} />}
          waitingCount={tickets.filter((t) => t.status === 'Waiting').length}
          servingCount={tickets.filter((t) => t.status === 'Serving').length}
        />
      )}
    </DashboardShell>
  )
}
