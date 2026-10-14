import Link from 'next/link'
import type { MyQueueStatus } from '@/lib/data/queue'
import { isActiveTicketStatus } from '@/lib/queue/line'

// A one-line pointer on the Enrollment and Document requests pages to the student's Queue page, where the
// QR code and the line live. Shows the ticket while the student is in the line.
export default function QueueNotice({ status, text }: { status: MyQueueStatus | null; text: string }) {
  const inLine = status?.hasTicket === true && isActiveTicketStatus(status.ticketStatus)
  return (
    <p role="status" className="rounded-md border border-edge bg-card px-4 py-3 text-sm text-ink">
      {inLine ? (
        <>
          {status.ticketStatus === 'Serving' ? 'It is your turn' : status.ticketStatus === 'Held' ? 'Your place is on hold' : 'You are in the line'}: ticket{' '}
          <span className="font-bold tabular-nums">{status.ticketLabel}</span>.{' '}
        </>
      ) : (
        <>{text} </>
      )}
      <Link href="/student/queue" className="font-semibold underline underline-offset-2">
        Open the Queue page
      </Link>
    </p>
  )
}
