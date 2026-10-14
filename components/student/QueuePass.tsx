'use client'

import { useEffect, useRef, useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { QRCodeSVG } from 'qrcode.react'
import { AutoRefresh } from '@/components/queue/AutoRefresh'
import { Button, Card } from '@/components/ui'
import type { MyQueueStatus, QueueService } from '@/lib/data/queue'
import { cancelMyTicket, getMyQueueQr, holdMyTicket, unholdMyTicket, type QueueActionState } from '@/lib/data/queue-actions'
import { Icon } from '@/components/layout/Icon'
import { estimateWait, formatWait, isActiveTicketStatus, lineSlots, MINUTES_PER_PERSON } from '@/lib/queue/line'
import { ordinal } from '@/lib/queue/ordinal'
import { cn } from '@/lib/utils'

const WINDOW_SECONDS = 30 // the same as QR_WINDOW_SECONDS in lib/queue/qr-token.ts (that file is server-only)

// The student's queue pass for a service: a rotating QR code to show at the Registrar, and once the
// Registrar has scanned it, the ticket number, the people ahead and the number being served. The page
// re-reads the queue every few seconds. Only the student's own ticket and plain numbers are shown.
export default function QueuePass({
  service,
  status,
  title,
  intro,
}: {
  service: QueueService
  status: MyQueueStatus | null
  title: string
  intro: string
}) {
  const active = status?.hasTicket && isActiveTicketStatus(status.ticketStatus)
  const served = status?.hasTicket && status.ticketStatus === 'Done'

  return (
    <Card tone="warm" className="flex flex-col gap-5 p-5 sm:p-6">
      <AutoRefresh everySeconds={10} />
      <div className="flex items-start gap-3">
        <span aria-hidden="true" className="grid size-10 shrink-0 place-items-center rounded-xl bg-gold text-[#18181b]">
          <Icon name="queue" className="size-5" />
        </span>
        <div>
          <h2 className="text-lg leading-tight font-semibold">{title}</h2>
          <p className="mt-1 max-w-[60ch] text-sm leading-6 text-muted">{intro}</p>
        </div>
      </div>

      {status === null ? (
        <p role="alert" className="rounded-xl bg-danger-soft px-4 py-3 text-sm font-medium text-danger">
          We could not load the queue. Reload the page, and if it keeps happening, come back in a few minutes.
        </p>
      ) : !status.isOpen ? (
        <p role="status" className="rounded-xl border border-edge bg-card px-4 py-3 text-sm font-medium">
          The queue is closed right now. Come back when the Registrar opens it.
        </p>
      ) : active ? (
        <TicketView service={service} status={status} />
      ) : served ? (
        // Served once today, but the pass is only shown while there is still a reason to queue (another open
        // request, a pending enrollment), so the code is offered again for a new number.
        <>
          <p role="status" className="rounded-xl border border-edge bg-card px-4 py-3 text-sm leading-6">
            <span className="font-semibold">You were served today ({status.ticketLabel}).</span> Need another number for a new
            request? Show the code below.
          </p>
          <QrView closedNote={null} />
        </>
      ) : (
        <QrView closedNote={status.hasTicket ? `Your last ticket (${status.ticketLabel}) was closed. Show the code again to get a new number.` : null} />
      )}
    </Card>
  )
}

function QrView({ closedNote }: { closedNote: string | null }) {
  const [token, setToken] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [left, setLeft] = useState(WINDOW_SECONDS)
  const deadline = useRef(0)

  useEffect(() => {
    let alive = true
    let timer: ReturnType<typeof setTimeout> | undefined

    async function load() {
      const res = await getMyQueueQr()
      if (!alive) return
      if (res.status === 'ok') {
        setToken(res.token)
        setError(null)
        deadline.current = Date.now() + res.refreshInSeconds * 1000
        timer = setTimeout(load, res.refreshInSeconds * 1000)
      } else {
        setError(res.message)
        timer = setTimeout(load, 10_000)
      }
    }

    void load()
    const tick = setInterval(() => setLeft(Math.max(0, Math.ceil((deadline.current - Date.now()) / 1000))), 500)
    return () => {
      alive = false
      clearTimeout(timer)
      clearInterval(tick)
    }
  }, [])

  return (
    <div className="grid gap-5 sm:grid-cols-[auto_1fr] sm:items-center sm:gap-7">
      <div className="mx-auto flex w-full max-w-[16.5rem] flex-col items-center gap-3 sm:mx-0">
        <div className="rounded-3xl bg-white p-3 shadow-elev-md ring-1 ring-black/5">
          {token ? (
            <QRCodeSVG value={token} size={208} level="M" marginSize={1} bgColor="#ffffff" fgColor="#18181b" title="Your queue code, it changes every 30 seconds" />
          ) : (
            <div className="grid size-[208px] place-items-center text-sm text-[#52525b]" aria-busy={!error}>
              {error ? 'No code yet' : 'Making your code...'}
            </div>
          )}
        </div>
        <div className="w-full">
          <div aria-hidden="true" className="h-1.5 w-full overflow-hidden rounded-full bg-hover-tint">
            <div
              className="h-full rounded-full bg-gold transition-[width] duration-500 ease-linear motion-reduce:transition-none"
              style={{ width: `${(left / WINDOW_SECONDS) * 100}%` }}
            />
          </div>
          <p className="mt-1.5 text-center text-xs text-muted tabular-nums">New code in {left}s</p>
        </div>
      </div>

      <div className="flex flex-col gap-4 text-sm leading-6">
        {error && (
          <p role="alert" className="rounded-xl bg-danger-soft px-4 py-3 font-medium text-danger">
            {error}
          </p>
        )}
        {closedNote && <p className="rounded-xl border border-edge bg-card px-4 py-3 font-medium">{closedNote}</p>}
        <div>
          <p className="text-base font-semibold">How to get your number</p>
          <ol className="mt-2 flex flex-col gap-2.5">
            {[
              'Go to the Registrar window at the school.',
              'Hold this code up to the Registrar\u2019s camera or scanner.',
              'Your queue number appears here right away. Keep this page open.',
            ].map((step, i) => (
              <li key={step} className="flex items-start gap-3">
                <span className="mt-0.5 grid size-6 shrink-0 place-items-center rounded-full bg-gold text-xs font-extrabold text-[#18181b]">
                  {i + 1}
                </span>
                <span>{step}</span>
              </li>
            ))}
          </ol>
        </div>
        <p className="text-[13px] text-muted">
          The code changes every 30 seconds, so a screenshot of it will not work.
        </p>
      </div>
    </div>
  )
}

function TicketView({ service, status }: { service: QueueService; status: MyQueueStatus }) {
  const router = useRouter()
  const [pending, startTransition] = useTransition()
  const [message, setMessage] = useState('')
  const [confirming, setConfirming] = useState(false)
  const serving = status.ticketStatus === 'Serving'
  const held = status.ticketStatus === 'Held'
  const place = status.peopleAhead + 1
  const wait = estimateWait(status.peopleAhead)

  function run(action: () => Promise<QueueActionState>) {
    setMessage('')
    startTransition(async () => {
      const res = await action()
      if (res.status === 'error') setMessage(res.message)
      setConfirming(false)
      router.refresh()
    })
  }

  const pill = serving ? 'Your turn' : held ? 'On hold' : status.peopleAhead === 0 ? 'You are next' : `${ordinal(place)} in line`

  return (
    <div role="status" aria-live="polite" className="flex flex-col gap-5">
      {/* The ticket: the number is the one thing to remember. */}
      <div className="flex flex-wrap items-end justify-between gap-x-6 gap-y-3 rounded-3xl bg-ink px-5 py-5 text-ink-foreground shadow-elev-md">
        <div>
          <p className="text-[13px] font-semibold tracking-wide text-white/70 uppercase">Your ticket</p>
          <p className="mt-1 text-5xl leading-none font-extrabold tracking-tight text-gold tabular-nums sm:text-6xl">{status.ticketLabel}</p>
        </div>
        <p className={cn('rounded-full px-4 py-1.5 text-sm font-bold text-[#18181b]', serving ? 'bg-success-soft text-success' : held ? 'bg-white/85' : 'bg-gold')}>
          {pill}
        </p>
      </div>

      {serving ? (
        <div className="rounded-3xl bg-success-soft px-5 py-5 text-success ring-2 ring-success motion-safe:animate-pulse">
          <p className="text-2xl font-extrabold">It is your turn</p>
          <p className="mt-1 text-lg font-semibold">
            {status.windowLabel ? `Go to ${status.windowLabel} now.` : 'Go to the Registrar window now.'}
          </p>
          <p className="mt-2 text-sm">Bring a valid ID. The Registrar will check it against your name.</p>
        </div>
      ) : held ? (
        <div className="flex flex-col gap-4 rounded-3xl border border-warm-edge bg-warm-glass px-5 py-5">
          <div>
            <p className="text-xl font-extrabold">Your place is on hold</p>
            <p className="mt-1 text-sm leading-6">
              The Registrar skips your number and serves the people behind you. When you are back at the school, tap{' '}
              <strong>I&apos;m back</strong> and you will be next.
            </p>
          </div>
          {status.heldUntil && <HoldCountdown until={status.heldUntil} />}
          <div className="flex flex-wrap items-center gap-3">
            <Button onClick={() => run(() => unholdMyTicket(service))} disabled={pending} aria-busy={pending}>
              {pending ? 'Please wait...' : "I'm back"}
            </Button>
            <CancelControl confirming={confirming} setConfirming={setConfirming} pending={pending} onConfirm={() => run(() => cancelMyTicket(service))} />
          </div>
        </div>
      ) : (
        <>
          <LineView position={place} waitingTotal={status.waitingTotal} />

          <dl className="grid grid-cols-1 gap-3 text-sm sm:grid-cols-3">
            <div className="rounded-2xl border border-edge bg-card px-4 py-3">
              <dt className="text-[13px] text-muted">People ahead of you</dt>
              <dd className="text-3xl font-extrabold tabular-nums">{status.peopleAhead}</dd>
            </div>
            <div className="rounded-2xl border border-edge bg-card px-4 py-3">
              <dt className="text-[13px] text-muted">Estimated wait</dt>
              <dd className="text-3xl font-extrabold">{wait ? formatWait(wait) : 'Any moment'}</dd>
              {wait && <p className="text-[12px] text-muted">about {MINUTES_PER_PERSON.min} to {MINUTES_PER_PERSON.max} min each</p>}
            </div>
            <div className="rounded-2xl border border-edge bg-card px-4 py-3">
              <dt className="text-[13px] text-muted">Now serving</dt>
              <dd className="text-3xl font-extrabold tabular-nums">{status.nowServing ?? '-'}</dd>
              {!status.nowServing && <p className="text-[12px] text-muted">nobody has been called yet</p>}
            </div>
          </dl>

          <div className="flex flex-col gap-3 rounded-2xl border border-edge bg-card px-4 py-4">
            <p className="text-sm leading-6">
              <span className="font-semibold">Stay near the Registrar.</span> If you are not at the window when your number is
              called, it is skipped. This page updates by itself.
            </p>
            <div className="flex flex-wrap items-center gap-3">
              <Button variant="outline" onClick={() => run(() => holdMyTicket(service))} disabled={pending} aria-busy={pending}>
                Hold my place
              </Button>
              <CancelControl confirming={confirming} setConfirming={setConfirming} pending={pending} onConfirm={() => run(() => cancelMyTicket(service))} />
            </div>
            <p className="text-[13px] leading-5 text-muted">
              Need a short break (bathroom, an emergency)? Hold your place. The line moves on without you, and when you tap
              I&apos;m back you are next.
            </p>
          </div>
        </>
      )}

      {message && (
        <p role="alert" className="rounded-xl bg-danger-soft px-4 py-3 text-sm font-medium text-danger">
          {message}
        </p>
      )}
    </div>
  )
}

function CancelControl({
  confirming,
  setConfirming,
  pending,
  onConfirm,
}: {
  confirming: boolean
  setConfirming: (v: boolean) => void
  pending: boolean
  onConfirm: () => void
}) {
  return confirming ? (
    <span className="flex flex-wrap items-center gap-2">
      <span className="text-sm font-medium">Cancel your ticket? You lose your place.</span>
      <Button variant="danger" onClick={onConfirm} disabled={pending} aria-busy={pending}>
        {pending ? 'Cancelling...' : 'Yes, cancel'}
      </Button>
      <Button variant="ghost" onClick={() => setConfirming(false)} disabled={pending}>
        Keep my place
      </Button>
    </span>
  ) : (
    <Button variant="ghost" onClick={() => setConfirming(true)} disabled={pending}>
      Cancel ticket
    </Button>
  )
}

// Time left on a hold, counted down on the student's phone.
function HoldCountdown({ until }: { until: string }) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(id)
  }, [])
  const left = Math.max(0, Math.ceil((new Date(until).getTime() - now) / 1000))
  const mm = String(Math.floor(left / 60)).padStart(1, '0')
  const ss = String(left % 60).padStart(2, '0')
  return left > 0 ? (
    <p className="text-sm">
      Time left on hold: <span className="font-bold tabular-nums">{mm}:{ss}</span>. After that your ticket can be marked as a no-show.
    </p>
  ) : (
    <p className="text-sm font-medium text-danger">Your hold has run out. The Registrar can mark your ticket as a no-show.</p>
  )
}

// The line, drawn from the window on the left to the back of the line on the right: the people ahead of
// you, you, and the people behind. Decorative: the text above and below says the same in words.
function LineView({ position, waitingTotal }: { position: number; waitingTotal: number }) {
  const slots = lineSlots(position, waitingTotal)

  return (
    <div aria-hidden="true" className="flex flex-col gap-2">
      <div className="flex items-center justify-between text-[11px] font-semibold tracking-wide text-muted uppercase">
        <span>Window</span>
        <span>Back of the line</span>
      </div>
      <ol className="flex flex-wrap items-center gap-2 rounded-2xl border border-edge bg-card px-3 py-3">
        <li className="mr-1 grid size-9 shrink-0 place-items-center rounded-lg bg-ink text-ink-foreground">
          <Icon name="users" className="size-4" />
        </li>
        {slots.map((slot, i) =>
          slot.kind === 'gap' ? (
            <li key={`gap-${i}`} className="px-1 text-lg leading-none font-bold text-muted">
              &hellip;
            </li>
          ) : slot.kind === 'you' ? (
            <li key={`you-${slot.position}`} className="flex h-9 shrink-0 items-center gap-1.5 rounded-full bg-gold px-3.5 text-sm font-extrabold text-[#18181b] shadow-elev-sm ring-2 ring-[#18181b]/15">
              You
              <span className="rounded-full bg-[#18181b]/10 px-1.5 text-xs tabular-nums">{slot.position}</span>
            </li>
          ) : (
            <li
              key={`${slot.kind}-${slot.position}`}
              className={cn(
                'grid size-9 shrink-0 place-items-center rounded-full text-sm font-semibold tabular-nums',
                slot.kind === 'ahead' ? 'bg-hover-tint text-foreground ring-1 ring-edge' : 'text-muted ring-1 ring-edge ring-dashed'
              )}
            >
              {slot.position}
            </li>
          )
        )}
      </ol>
    </div>
  )
}
