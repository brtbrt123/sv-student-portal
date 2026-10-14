import Link from 'next/link'
import DashboardShell from '@/components/layout/DashboardShell'
import { AutoRefresh } from '@/components/queue/AutoRefresh'
import QueueDesk from '@/components/registrar/QueueDesk'
import QueueScanner from '@/components/registrar/QueueScanner'
import TicketQueue from '@/components/registrar/TicketQueue'
import { EmptyState } from '@/components/ui'
import { requireRole } from '@/lib/auth/session'
import { getStaffQueue, isQueueService, type QueueService, type StaffTicket } from '@/lib/data/queue'
import { cn } from '@/lib/utils'

const LINES: { service: QueueService; label: string; subtitle: string }[] = [
  { service: 'Enrollment', label: 'Enrollment', subtitle: 'enrollment line for today' },
  { service: 'Documents', label: 'Documents', subtitle: 'document claim line for today' },
]

const active = (tickets: StaffTicket[] | null) =>
  tickets === null ? 0 : tickets.filter((t) => t.status === 'Waiting' || t.status === 'Held' || t.status === 'Serving').length

// The lines at the Registrar window: scan a student's rotating QR code to issue a ticket, call the next
// number, finish it. There is one line per service (Enrollment, Documents); `?service=Documents` picks the
// document claim line. Students see their own number and the number being served on their Enrollment or
// Document requests page.
export default async function RegistrarQueuePage({
  searchParams,
}: {
  searchParams: Promise<{ [key: string]: string | string[] | undefined }>
}) {
  const profile = await requireRole('Registrar')
  const { service: serviceParam } = await searchParams
  const service: QueueService = isQueueService(serviceParam) ? serviceParam : 'Enrollment'
  const [enrollment, documents] = await Promise.all([getStaffQueue('Enrollment'), getStaffQueue('Documents')])
  const tickets = service === 'Documents' ? documents : enrollment
  const counts: Record<QueueService, number> = { Enrollment: active(enrollment), Documents: active(documents) }
  const current = LINES.find((l) => l.service === service) ?? LINES[0]

  return (
    <DashboardShell profile={profile} title="Queue" subtitle={`Registrar Office · ${current.subtitle}`}>
      <AutoRefresh everySeconds={5} />
      <nav aria-label="Choose the line" className="glass mb-4 grid grid-cols-2 gap-1 rounded-full border border-border bg-card p-1 sm:max-w-md">
        {LINES.map((l) => {
          const on = l.service === service
          return (
            <Link
              key={l.service}
              href={l.service === 'Enrollment' ? '/registrar/queue' : `/registrar/queue?service=${l.service}`}
              aria-current={on ? 'page' : undefined}
              className={cn(
                'flex h-11 min-w-0 items-center justify-center gap-2 rounded-full px-3 text-sm font-semibold transition-colors focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-ring',
                on ? 'bg-primary text-primary-foreground' : 'text-muted hover:bg-hover-tint hover:text-foreground'
              )}
            >
              {l.label}
              <span
                className={cn(
                  'grid h-6 min-w-6 place-items-center rounded-full px-1.5 text-xs font-bold tabular-nums',
                  on ? 'bg-primary-foreground/20' : 'bg-gold text-[#18181b]'
                )}
              >
                {counts[l.service]}
              </span>
            </Link>
          )
        })}
      </nav>
      {tickets === null ? (
        <div role="alert">
          <EmptyState title="We could not load the queue">
            Something went wrong on our side. Reload the page, and if it keeps happening, come back in a few minutes.
          </EmptyState>
        </div>
      ) : (
        <QueueDesk
          key={service}
          scanner={<QueueScanner service={service} />}
          line={<TicketQueue service={service} tickets={tickets} />}
          waitingCount={tickets.filter((t) => t.status === 'Waiting').length}
          servingCount={tickets.filter((t) => t.status === 'Serving').length}
        />
      )}
    </DashboardShell>
  )
}
