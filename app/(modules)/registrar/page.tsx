import Link from 'next/link'
import { requireRole } from '@/lib/auth/session'
import DashboardShell from '@/components/layout/DashboardShell'
import { EmptyRow, EmptyState, Section, StatusBadge, SummaryStrip, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui'
import { QueueSheet, QueueTable, StudentCell } from '@/components/registrar/QueueParts'
import { getRegistrarClearanceState } from '@/lib/data/registrar'
import { getRegistrarDashboard } from '@/lib/data/dashboards'

const OPEN_LINK =
  'inline-flex h-9 items-center text-sm font-semibold text-accent-foreground hover:underline max-lg:h-11 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring rounded-md'

const dateFormat = new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Manila', day: '2-digit', month: 'short', year: 'numeric' })

function day(iso: string): string {
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? iso : dateFormat.format(d)
}

function CouldNotLoad({ what }: { what: string }) {
  return (
    <div role="alert">
      <EmptyState title={`We could not load ${what}`}>Reload the page. If it keeps happening, come back in a few minutes.</EmptyState>
    </div>
  )
}

export default async function RegistrarDashboardPage() {
  const profile = await requireRole('Registrar')

  const [dash, clearanceState] = await Promise.all([getRegistrarDashboard(), getRegistrarClearanceState()])
  const { applications, enrollments, documents, queue } = dash

  const clearancesLoaded = clearanceState.kind === 'ready'
  const readyClearances = clearanceState.kind === 'ready' ? clearanceState.clearances.filter((c) => !c.approved && c.ready) : []
  const toProcess = documents.kind === 'ready' ? documents.pending + documents.processing : 0

  return (
    <DashboardShell profile={profile} title="Dashboard" subtitle="Registrar Office, 1st Sem 2026-2027">
      <div className="flex flex-col gap-6">
        <SummaryStrip
          items={[
            {
              label: 'Applications',
              value: applications.kind === 'ready' ? applications.pending : '-',
              hint: applications.kind === 'ready' ? 'pending review' : 'could not load',
              hue: applications.kind === 'ready' && applications.pending ? 'amber' : undefined,
            },
            {
              label: 'Enrollments',
              value: enrollments.kind === 'ready' ? enrollments.pending : '-',
              hint: enrollments.kind === 'ready' ? 'awaiting review' : 'could not load',
              hue: enrollments.kind === 'ready' && enrollments.pending ? 'amber' : undefined,
            },
            {
              label: 'Document requests',
              value: documents.kind === 'ready' ? toProcess : '-',
              hint: documents.kind === 'ready' ? `to process, ${documents.ready} ready` : 'could not load',
              hue: toProcess ? 'amber' : undefined,
            },
            {
              label: 'Clearances',
              value: clearancesLoaded ? readyClearances.length : '-',
              hint: clearancesLoaded ? 'ready for final approval' : 'could not load',
              hue: readyClearances.length ? 'teal' : undefined,
            },
          ]}
        />

        <Section title="Applications" action={<Link href="/registrar/applications" className={OPEN_LINK}>Review applications</Link>}>
          {applications.kind === 'error' ? (
            <CouldNotLoad what="applications" />
          ) : (
            <p className="text-sm text-muted">
              {applications.pending === 0
                ? 'No applications are waiting for review.'
                : `${applications.pending} ${applications.pending === 1 ? 'application is' : 'applications are'} waiting for review.`}
            </p>
          )}
        </Section>

        <Section title="Today's queue" action={<Link href="/registrar/queue" className={OPEN_LINK}>Open queue</Link>}>
          {queue.kind === 'error' ? (
            <CouldNotLoad what="the queue" />
          ) : (
            <QueueSheet>
              <QueueTable minWidth="min-w-[420px]">
                <TableHeader>
                  <tr>
                    <TableHead>Service</TableHead>
                    <TableHead>Waiting</TableHead>
                    <TableHead>Serving</TableHead>
                    <TableHead>On hold</TableHead>
                  </tr>
                </TableHeader>
                <TableBody>
                  {[
                    { service: 'Enrollment', c: queue.enrollment },
                    { service: 'Documents', c: queue.documents },
                  ].map(({ service, c }) => (
                    <TableRow key={service}>
                      <TableCell className="font-semibold">{service}</TableCell>
                      <TableCell className="text-muted">{c.waiting}</TableCell>
                      <TableCell className="text-muted">{c.serving}</TableCell>
                      <TableCell className="text-muted">{c.held}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </QueueTable>
            </QueueSheet>
          )}
        </Section>

        <Section
          title="Pending enrollments"
          action={<Link href="/registrar/enrollments" className={OPEN_LINK}>Review enrollments</Link>}
        >
          {enrollments.kind === 'error' ? (
            <CouldNotLoad what="enrollments" />
          ) : (
            <QueueSheet>
              <QueueTable minWidth="min-w-[600px]">
                <TableHeader>
                  <tr>
                    <TableHead>Student</TableHead>
                    <TableHead>Term</TableHead>
                    <TableHead>Year level</TableHead>
                    <TableHead>Subjects</TableHead>
                    <TableHead>Status</TableHead>
                    <TableHead>Submitted</TableHead>
                  </tr>
                </TableHeader>
                <TableBody>
                  {enrollments.rows.length === 0 && <EmptyRow colSpan={6}>No enrollments are waiting for review.</EmptyRow>}
                  {enrollments.rows.map((e) => (
                    <TableRow key={e.id}>
                      <TableCell><StudentCell name={e.studentName} sub={e.studentNo} /></TableCell>
                      <TableCell className="text-muted">{e.termLabel}</TableCell>
                      <TableCell className="text-muted">Year {e.yearLevel}</TableCell>
                      <TableCell className="text-muted">{e.sections.length} {e.sections.length === 1 ? 'subject' : 'subjects'}</TableCell>
                      <TableCell><StatusBadge status={e.status} /></TableCell>
                      <TableCell className="text-muted">{day(e.submittedAt)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </QueueTable>
            </QueueSheet>
          )}
          {enrollments.kind === 'ready' && enrollments.pending > enrollments.rows.length && (
            <p className="mt-2 text-sm text-muted">Showing {enrollments.rows.length} of {enrollments.pending} pending enrollments.</p>
          )}
        </Section>

        <Section
          title="Open document requests"
          action={<Link href="/registrar/documents" className={OPEN_LINK}>Open document requests</Link>}
        >
          {documents.kind === 'error' ? (
            <CouldNotLoad what="document requests" />
          ) : (
            <>
              <p className="mb-2 text-sm text-muted">
                {documents.pending} pending, {documents.processing} processing, {documents.ready} ready for release.
              </p>
              <QueueSheet>
                <QueueTable minWidth="min-w-[600px]">
                  <TableHeader>
                    <tr>
                      <TableHead>Ticket</TableHead>
                      <TableHead>Student</TableHead>
                      <TableHead>Document</TableHead>
                      <TableHead>Copies</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead>Requested</TableHead>
                    </tr>
                  </TableHeader>
                  <TableBody>
                    {documents.rows.length === 0 && <EmptyRow colSpan={6}>No open document requests.</EmptyRow>}
                    {documents.rows.map((d) => (
                      <TableRow key={d.id}>
                        <TableCell className="text-muted">{d.ticketNumber}</TableCell>
                        <TableCell><StudentCell name={d.studentName} sub={d.studentNo} /></TableCell>
                        <TableCell>{d.typeName}</TableCell>
                        <TableCell className="text-muted">{d.copies}</TableCell>
                        <TableCell><StatusBadge status={d.status} /></TableCell>
                        <TableCell className="text-muted">{day(d.requestedAt)}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </QueueTable>
              </QueueSheet>
            </>
          )}
        </Section>
      </div>
    </DashboardShell>
  )
}
