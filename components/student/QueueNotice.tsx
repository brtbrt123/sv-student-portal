import Link from 'next/link'
import { Icon } from '@/components/layout/Icon'
import type { MyQueueStatus } from '@/lib/data/queue'
import { isActiveTicketStatus } from '@/lib/queue/line'

// A short card on the Enrollment and Document requests pages that points to the student's Queue page, where the
// QR code and the line live. While the student is in the line it shows the ticket and what is happening instead.
export default function QueueNotice({ status, text }: { status: MyQueueStatus | null; text: string }) {
  const inLine = status?.hasTicket === true && isActiveTicketStatus(status.ticketStatus)
  const serving = inLine && status.ticketStatus === 'Serving'
  const held = inLine && status.ticketStatus === 'Held'

  return (
    <div
      role="status"
      className="flex flex-wrap items-center gap-x-4 gap-y-3 rounded-2xl border border-warm-edge bg-warm-glass px-4 py-3.5 text-foreground"
    >
      <span aria-hidden="true" className="grid size-10 shrink-0 place-items-center rounded-xl bg-gold text-[#18181b]">
        <Icon name="queue" className="size-5" />
      </span>
      <div className="min-w-0 flex-1 basis-56">
        {inLine ? (
          <>
            <p className="text-sm font-semibold">
              {serving ? 'It is your turn' : held ? 'Your place is on hold' : 'You are in the line'}
              {': ticket '}
              <span className="font-extrabold tabular-nums">{status.ticketLabel}</span>
            </p>
            <p className="text-[13px] text-muted">
              {serving
                ? 'Go to the window now.'
                : held
                  ? 'Tap I’m back on the Queue page when you return.'
                  : 'Follow your place in line on the Queue page.'}
            </p>
          </>
        ) : (
          <>
            <p className="text-sm font-semibold">Need to go to the Registrar&apos;s window?</p>
            <p className="text-[13px] text-muted">{text}</p>
          </>
        )}
      </div>
      <Link
        href="/student/queue"
        className="inline-flex h-11 items-center rounded-full bg-primary px-5 text-sm font-semibold text-primary-foreground transition-colors hover:bg-primary-hover focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
      >
        Open the Queue page
      </Link>
    </div>
  )
}
