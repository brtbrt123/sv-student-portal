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
      <AutoRefresh everySeconds={active ? 10 : 5} />
      <div>
        <h2 className="text-lg font-semibold">{title}</h2>
        <p className="mt-1 max-w-[60ch] text-sm leading-6 text-muted">{intro}</p>
      </div>

      {status === null ? (
        <p role="alert" className="rounded-md bg-danger-soft px-3 py-2 text-sm text-danger">
          We could not load the queue. Reload the page, and if it keeps happening, come back in a few minutes.
        </p>
      ) : !status.isOpen ? (
        <p role="status" className="rounded-md border border-edge bg-card px-3 py-2 text-sm">
          The queue is closed right now. Come back when the Registrar opens it.
        </p>
      ) : active ? (
        <TicketView service={service} status={status} />
      ) : served ? (
        <p role="status" className="rounded-md border border-edge bg-card px-4 py-3 text-sm font-medium">
          You were served today ({status.ticketLabel}). You are all set.
        </p>
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
    <div className="flex flex-col items-start gap-4 sm:flex-row sm:items-center sm:gap-6">
      <div className="flex flex-col items-center gap-2">
        <div className="rounded-2xl bg-white p-3 shadow-elev-sm">
          {token ? (
            <QRCodeSVG value={token} size={208} level="M" marginSize={1} bgColor="#ffffff" fgColor="#18181b" title="Your queue code, it changes every 30 seconds" />
          ) : (
            <div className="grid size-[208px] place-items-center text-sm text-[#52525b]" aria-busy={!error}>
              {error ? 'No code yet' : 'Making your code...'}
            </div>
          )}
        </div>
        <div aria-hidden="true" className="h-1.5 w-full overflow-hidden rounded-full bg-hover-tint">
          <div
            className="h-full rounded-full bg-gold transition-[width] duration-500 ease-linear motion-reduce:transition-none"
            style={{ width: `${(left / WINDOW_SECONDS) * 100}%` }}
          />
        </div>
      </div>
      <div className="flex max-w-[44ch] flex-col gap-2 text-sm leading-6">
        {error && (
          <p role="alert" className="rounded-md bg-danger-soft px-3 py-2 text-danger">
            {error}
          </p>
        )}
        {closedNote && <p className="font-medium">{closedNote}</p>}
        <p>
          <span className="font-semibold">At the school,</span> hold this code up to the Registrar&apos;s scanner. You get your queue
          number right away.
        </p>
        <p className="text-muted">
          The code changes every 30 seconds, so a screenshot of it will not work. Keep this page open on your phone.
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

  return (
    <div role="status" aria-live="polite" className="flex flex-col gap-5">
      <div className="flex flex-wrap items-end justify-between gap-x-6 gap-y-2">
        <div>
          <p className="text-[13px] font-medium text-muted">Your ticket</p>
          <p className="text-4xl leading-none font-extrabold tracking-tight tabular-nums sm:text-5xl">{status.ticketLabel}</p>
        </div>
        {!serving && !held && (
          <p className="rounded-full bg-gold px-4 py-1.5 text-sm font-bold text-[#18181b]">
            {status.peopleAhead === 0 ? 'You are next' : `${ordinal(place)} in line`}
          </p>
        )}
      </div>

      {serving ? (
        <div className="rounded-2xl bg-success-soft px-5 py-5 text-success ring-2 ring-success motion-safe:animate-pulse">
          <p className="text-2xl font-extrabold">It is your turn</p>
          <p className="mt-1 text-base font-semibold">
            {status.windowLabel ? `Go to ${status.windowLabel} now.` : 'Go to the Registrar window now.'}
          </p>
          <p className="mt-1 text-sm">Bring your valid ID and your requirements.</p>
        </div>
      ) : held ? (
        <div className="flex flex-col gap-4 rounded-2xl border border-warm-edge bg-warm-glass px-5 py-5">
          <div>
            <p className="text-xl font-extrabold">Your place is on hold</p>
            <p className="mt-1 text-sm leading-6">
              The Registrar skips your number and calls the people behind you. Tap <strong>I&apos;m back</strong> when you are at the
              school again and you will be next.
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

          <dl className="grid grid-cols-2 gap-3 text-sm">
            <div className="rounded-xl border border-edge bg-card px-4 py-3">
              <dt className="text-[13px] text-muted">People ahead</dt>
              <dd className="text-2xl font-bold tabular-nums">{status.peopleAhead}</dd>
            </div>
            <div className="rounded-xl border border-edge bg-card px-4 py-3">
              <dt className="text-[13px] text-muted">Estimated wait</dt>
              <dd className="text-2xl font-bold">{wait ? formatWait(wait) : 'Any moment'}</dd>
              {wait && <p className="text-[13px] text-muted">about {MINUTES_PER_PERSON.min} to {MINUTES_PER_PERSON.max} min each</p>}
            </div>
          </dl>
          <p className="text-sm text-muted">
            {status.nowServing ? `Last called: ${status.nowServing}. ` : 'Nobody has been called yet. '}
            The page updates by itself.
          </p>

          <div className="flex flex-wrap items-center gap-3">
            <Button variant="outline" onClick={() => run(() => holdMyTicket(service))} disabled={pending} aria-busy={pending}>
              Hold my place
            </Button>
            <CancelControl confirming={confirming} setConfirming={setConfirming} pending={pending} onConfirm={() => run(() => cancelMyTicket(service))} />
          </div>
          <p className="text-sm text-muted">
            Need a short break (bathroom, an emergency)? Hold your place: the line moves on without you and when you are back you are next.
            Stay close to the Registrar: if you are not at the window when your number is called, it is skipped.
          </p>
        </>
      )}

      {message && (
        <p role="alert" className="rounded-md bg-danger-soft px-3 py-2 text-sm text-danger">
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
