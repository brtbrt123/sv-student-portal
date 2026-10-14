'use client'

import { useActionState } from 'react'
import { Icon } from '@/components/layout/Icon'
import { Button, Card, CardHeader } from '@/components/ui'
import type { QueueService, StaffTicket } from '@/lib/data/queue'
import { callNextTicket, finishTicket, type CallState, type QueueActionState } from '@/lib/data/queue-actions'

const CALL_INITIAL: CallState = { status: 'idle', message: '' }
const FINISH_INITIAL: QueueActionState = { status: 'idle', message: '' }

// Each line has its own window; the Registrar can still type another one when calling.
const DEFAULT_WINDOW: Record<QueueService, string> = { Enrollment: 'Window 1', Documents: 'Window 2' }

const clock = (iso: string) =>
  new Date(iso).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: 'Asia/Manila' })

// The Registrar's line for today: who is at the window (Done / No-show), the button that calls the next number, who
// is waiting, who is on hold, and today's totals. The page re-reads the data every few seconds.
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
        <CardHeader title="At the window" icon="queue" />
        {serving.length === 0 ? (
          <div className="flex flex-col gap-1 rounded-2xl border border-dashed border-field-border px-4 py-5 text-center">
            <p className="text-sm font-semibold">Nobody is at the window</p>
            <p className="text-[13px] text-muted">
              {waiting.length > 0 ? 'Press Call next to take the first student in line.' : 'When a student is scanned, their number appears in the line below.'}
            </p>
          </div>
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
        <CardHeader title={`In line (${waiting.length})`} icon="users" />
        {waiting.length === 0 ? (
          <div className="flex flex-col gap-1 rounded-2xl border border-dashed border-field-border px-4 py-5 text-center">
            <p className="text-sm font-semibold">Nobody is waiting</p>
            <p className="text-[13px] text-muted">New tickets appear here as soon as a student&apos;s code is scanned.</p>
          </div>
        ) : (
          <ol className="flex flex-col gap-2">
            {waiting.map((t, i) => (
              <li
                key={t.ticketId}
                className={`flex items-center gap-3 rounded-2xl border px-3 py-2.5 ${i === 0 ? 'border-warm-edge bg-warm-glass' : 'border-edge bg-card'}`}
              >
                <span
                  aria-hidden="true"
                  className={`grid size-8 shrink-0 place-items-center rounded-full text-sm font-extrabold tabular-nums ${i === 0 ? 'bg-gold text-[#18181b]' : 'bg-hover-tint text-foreground'}`}
                >
                  {i + 1}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-semibold">{t.studentName || 'Student'}</span>
                  <span className="block truncate text-[13px] text-muted tabular-nums">{t.studentNumber}</span>
                </span>
                <span className="shrink-0 text-right">
                  <span className="block text-base font-bold tabular-nums">{t.label}</span>
                  <span className="block text-[12px] text-muted">{i === 0 ? 'Next · ' : ''}since {clock(t.createdAt)}</span>
                </span>
              </li>
            ))}
          </ol>
        )}

        {held.length > 0 && (
          <div className="flex flex-col gap-2 border-t border-border pt-4">
            <h3 className="text-sm font-semibold">On hold ({held.length})</h3>
            <p className="text-[13px] leading-5 text-muted">
              These students stepped away. Call next skips them. When a student taps I&apos;m back, their number is next again. Mark a
              no-show if they do not return.
            </p>
            <ul className="flex flex-col gap-2">
              {held.map((t) => (
                <HeldRow key={t.ticketId} ticket={t} />
              ))}
            </ul>
          </div>
        )}

        <dl className="grid grid-cols-3 gap-2 border-t border-border pt-4 text-center">
          {[
            ['Served today', done],
            ['No-shows', skipped],
            ['Left the line', cancelled],
          ].map(([label, n]) => (
            <div key={label} className="rounded-xl bg-hover-tint px-2 py-2">
              <dd className="text-xl font-extrabold tabular-nums">{n}</dd>
              <dt className="text-[12px] text-muted">{label}</dt>
            </div>
          ))}
        </dl>
      </Card>
    </div>
  )
}

function CallNext({ service, waitingCount, holding }: { service: QueueService; waitingCount: number; holding: boolean }) {
  const [state, formAction, pending] = useActionState(callNextTicket, CALL_INITIAL)

  return (
    <form action={formAction} className="flex flex-col gap-3 border-t border-border pt-4">
      <input type="hidden" name="service" value={service} />
      <div className="flex flex-wrap items-end gap-3">
        <div className="flex flex-col gap-1">
          <label htmlFor="window-label" className="text-sm font-medium">
            Window
          </label>
          <input
            id="window-label"
            name="window"
            type="text"
            maxLength={40}
            defaultValue={DEFAULT_WINDOW[service]}
            placeholder={DEFAULT_WINDOW[service]}
            className="glass h-11 w-40 rounded-full border border-field-border bg-card px-4 text-sm text-foreground placeholder:text-muted"
          />
        </div>
        <Button type="submit" className="h-11 px-6" disabled={pending || holding || waitingCount === 0} aria-busy={pending}>
          {pending ? 'Calling...' : 'Call next'}
        </Button>
      </div>
      <p className="text-[13px] text-muted">
        {holding
          ? 'Finish the student at the window (Done or No-show) before calling the next one.'
          : waitingCount === 0
            ? 'Nobody is waiting, so there is no one to call.'
            : `${waitingCount} ${waitingCount === 1 ? 'student is' : 'students are'} waiting. The student sees the window you enter here.`}
      </p>
      <div role="status" aria-live="polite">
        {state.status === 'error' && <p className="rounded-xl bg-danger-soft px-4 py-3 text-sm font-medium text-danger">{state.message}</p>}
        {state.status === 'empty' && <p className="text-sm text-muted">{state.message}</p>}
      </div>
    </form>
  )
}

function ServingRow({ ticket }: { ticket: StaffTicket }) {
  const [state, formAction, pending] = useActionState(finishTicket, FINISH_INITIAL)

  return (
    <li className="flex flex-col gap-4 rounded-2xl bg-ink p-4 text-ink-foreground shadow-elev-md">
      <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
        <div className="flex min-w-0 items-center gap-4">
          <span className="text-4xl leading-none font-extrabold tracking-tight text-gold tabular-nums">{ticket.label}</span>
          <span className="min-w-0">
            <span className="block truncate text-base font-semibold">{ticket.studentName || 'Student'}</span>
            <span className="block truncate text-[13px] text-white/75 tabular-nums">{ticket.studentNumber}</span>
          </span>
        </div>
        <p className="rounded-full bg-white/10 px-3 py-1 text-xs font-semibold">
          {ticket.windowLabel ?? 'Window'}
          {ticket.calledAt ? ` · called ${clock(ticket.calledAt)}` : ''}
        </p>
      </div>
      <p className="flex items-start gap-2 text-[13px] leading-5 text-white/85">
        <Icon name="check" className="mt-0.5 size-4 shrink-0 text-gold" />
        Check the student&apos;s ID against this name before you finish.
      </p>
      <form action={formAction} className="flex flex-wrap gap-2">
        <input type="hidden" name="ticketId" value={ticket.ticketId} />
        <Button type="submit" name="outcome" value="Done" disabled={pending}>
          Done
        </Button>
        <button
          type="submit"
          name="outcome"
          value="No-show"
          disabled={pending}
          className="h-10 rounded-full border border-white/30 px-5 text-sm font-semibold text-white transition-colors hover:bg-white/10 focus-visible:outline-2 focus-visible:outline-white disabled:opacity-50"
        >
          No-show
        </button>
      </form>
      {state.status === 'error' && <p role="alert" className="rounded-xl bg-danger-soft px-4 py-3 text-sm font-medium text-danger">{state.message}</p>}
    </li>
  )
}

function HeldRow({ ticket }: { ticket: StaffTicket }) {
  const [state, formAction, pending] = useActionState(finishTicket, FINISH_INITIAL)

  return (
    <li className="flex flex-wrap items-center gap-x-3 gap-y-2 rounded-2xl border border-edge bg-card px-3 py-2.5">
      <span className="shrink-0 rounded-full bg-gold px-2.5 py-0.5 text-[11px] font-extrabold tracking-wide text-[#18181b] uppercase">On hold</span>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-sm font-semibold">{ticket.studentName || 'Student'}</span>
        <span className="block truncate text-[13px] text-muted tabular-nums">
          {ticket.label} · {ticket.studentNumber}
          {ticket.heldAt ? ` · since ${clock(ticket.heldAt)}` : ''}
          {ticket.heldUntil && !ticket.holdExpired ? ` · No-show allowed after ${clock(ticket.heldUntil)}` : ''}
        </span>
      </span>
      <form action={formAction}>
        <input type="hidden" name="ticketId" value={ticket.ticketId} />
        <Button type="submit" name="outcome" value="No-show" variant="outline" disabled={pending || !ticket.holdExpired}>
          No-show
        </Button>
      </form>
      {state.status === 'error' && <p role="alert" className="w-full rounded-xl bg-danger-soft px-4 py-3 text-sm font-medium text-danger">{state.message}</p>}
    </li>
  )
}
