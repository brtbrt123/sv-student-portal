'use client'

import { useActionState } from 'react'
import { Button, Card, CardHeader, EmptyState } from '@/components/ui'
import type { QueueService, StaffTicket } from '@/lib/data/queue'
import { callNextTicket, finishTicket, type CallState, type QueueActionState } from '@/lib/data/queue-actions'

const CALL_INITIAL: CallState = { status: 'idle', message: '' }
const FINISH_INITIAL: QueueActionState = { status: 'idle', message: '' }

// Each line has its own window; the Registrar can still type another one when calling.
const DEFAULT_WINDOW: Record<QueueService, string> = { Enrollment: 'Window 1', Documents: 'Window 2' }

const clock =(iso: string) => new Date(iso).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: 'Asia/Manila' })

// The Registrar's queue for today: who is being served (Done / No-show), who is waiting, a Call next
// button, and today's totals. The page re-reads the data every few seconds.
export default function TicketQueue({ service, tickets }: { service: QueueService; tickets: StaffTicket[] }) {
  const serving = tickets.filter((t) => t.status === 'Serving')
  const waiting = tickets.filter((t) => t.status === 'Waiting')
  const held = tickets.filter((t) => t.status === 'Held')
  const done = tickets.filter((t) => t.status === 'Done').length
  const skipped = tickets.filter((t) => t.status === 'No-show').length
  const cancelled = tickets.filter((t) => t.status === 'Cancelled').length

  return (
    <div className="flex flex-col gap-6">
      <Card className="flex flex-col gap-4 p-5">
        <CardHeader title="Now serving" icon="enrollment" />
        {serving.length === 0 ? (
          <p className="text-sm text-muted">Nobody is at the window. Press Call next to take the next student in line.</p>
        ) : (
          <ul className="flex flex-col gap-3">
            {serving.map((t) => (
              <ServingRow key={t.ticketId} ticket={t} />
            ))}
          </ul>
        )}
        <CallNext service={service} waitingCount={waiting.length} holding={serving.length > 0} />
      </Card>

      <Card className="flex flex-col gap-4 p-5">
        <CardHeader title={`Waiting (${waiting.length})`} icon="users" />
        {waiting.length === 0 ? (
          <EmptyState title="Nobody is waiting">New tickets appear here as soon as a student&apos;s code is scanned.</EmptyState>
        ) : (
          <ol className="flex flex-col divide-y divide-border">
            {waiting.map((t, i) => (
              <li key={t.ticketId} className="flex items-center gap-3 py-2.5">
                <span className="shrink-0 text-base font-bold tabular-nums">{t.label}</span>
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-semibold">{t.studentName || 'Student'}</span>
                  <span className="block truncate text-[13px] text-muted">{t.studentNumber}</span>
                </span>
                <span className="shrink-0 text-right text-[13px] text-muted">
                  {i === 0 ? 'Next' : `#${i + 1}`}
                  <span className="block">since {clock(t.createdAt)}</span>
                </span>
              </li>
            ))}
          </ol>
        )}
        {held.length > 0 && (
          <div className="flex flex-col gap-2 border-t border-border pt-4">
            <h3 className="text-sm font-semibold">On hold ({held.length})</h3>
            <p className="text-[13px] text-muted">
              Skipped by Call next. When the student taps I&apos;m back, their number is next again.
            </p>
            <ul className="flex flex-col divide-y divide-border">
              {held.map((t) => (
                <HeldRow key={t.ticketId} ticket={t} />
              ))}
            </ul>
          </div>
        )}
        <p className="text-[13px] text-muted">
          Today: {done} done, {skipped} no-show, {cancelled} left the queue.
        </p>
      </Card>
    </div>
  )
}

function CallNext({ service, waitingCount, holding }: { service: QueueService; waitingCount: number; holding: boolean }) {
  const [state, formAction, pending] = useActionState(callNextTicket, CALL_INITIAL)

  return (
    <form action={formAction} className="flex flex-col gap-2 border-t border-border pt-4">
      <input type="hidden" name="service" value={service} />
      <div className="flex flex-wrap items-end gap-3">
        <div className="flex flex-col gap-1">
          <label htmlFor="window-label" className="text-sm font-medium">
            Window (optional)
          </label>
          <input
            id="window-label"
            name="window"
            type="text"
            maxLength={40}
            defaultValue={DEFAULT_WINDOW[service]}
            placeholder={DEFAULT_WINDOW[service]}
            className="glass h-10 w-40 rounded-full border border-field-border bg-card px-4 text-sm text-foreground placeholder:text-muted max-lg:h-11"
          />
        </div>
        <Button type="submit" disabled={pending || holding || waitingCount === 0} aria-busy={pending}>
          {pending ? 'Calling...' : 'Call next'}
        </Button>
      </div>
      {holding && <p className="text-[13px] text-muted">Finish the ticket above (Done or No-show) before calling the next one.</p>}
      <div role="status" aria-live="polite">
        {state.status === 'error' && <p className="rounded-md bg-danger-soft px-3 py-2 text-sm text-danger">{state.message}</p>}
        {state.status === 'empty' && <p className="text-sm text-muted">{state.message}</p>}
      </div>
    </form>
  )
}

function HeldRow({ ticket }: { ticket: StaffTicket }) {
  const [state, formAction, pending] = useActionState(finishTicket, FINISH_INITIAL)

  return (
    <li className="flex flex-wrap items-center gap-x-3 gap-y-2 py-2.5">
      <span className="shrink-0 text-base font-bold tabular-nums">{ticket.label}</span>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-sm font-semibold">{ticket.studentName || 'Student'}</span>
        <span className="block truncate text-[13px] text-muted">
          {ticket.studentNumber}
          {ticket.heldAt ? ` · on hold since ${clock(ticket.heldAt)}` : ''}
        </span>
      </span>
      <form action={formAction}>
        <input type="hidden" name="ticketId" value={ticket.ticketId} />
        <Button type="submit" name="outcome" value="No-show" variant="outline" disabled={pending}>
          No-show
        </Button>
      </form>
      {state.status === 'error' && <p role="alert" className="w-full rounded-md bg-danger-soft px-3 py-2 text-sm text-danger">{state.message}</p>}
    </li>
  )
}

function ServingRow({ ticket }: { ticket: StaffTicket }) {
  const [state, formAction, pending] = useActionState(finishTicket, FINISH_INITIAL)

  return (
    <li className="flex flex-col gap-3 rounded-xl border border-warm-edge bg-warm-glass p-4">
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1">
        <span className="text-4xl leading-none font-extrabold tracking-tight tabular-nums">{ticket.label}</span>
        <span className="min-w-0">
          <span className="block truncate text-base font-semibold">{ticket.studentName || 'Student'}</span>
          <span className="block truncate text-[13px] text-muted">
            {ticket.studentNumber}
            {ticket.windowLabel ? ` · ${ticket.windowLabel}` : ''}
            {ticket.calledAt ? ` · called ${clock(ticket.calledAt)}` : ''}
          </span>
        </span>
      </div>
      <form action={formAction} className="flex flex-wrap gap-2">
        <input type="hidden" name="ticketId" value={ticket.ticketId} />
        <Button type="submit" name="outcome" value="Done" disabled={pending}>
          Done
        </Button>
        <Button type="submit" name="outcome" value="No-show" variant="outline" disabled={pending}>
          No-show
        </Button>
      </form>
      {state.status === 'error' && <p role="alert" className="rounded-md bg-danger-soft px-3 py-2 text-sm text-danger">{state.message}</p>}
    </li>
  )
}
