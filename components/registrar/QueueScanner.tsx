'use client'

import { useActionState, useEffect, useRef, useState } from 'react'
import jsQR from 'jsqr'
import { Button, Card, CardHeader } from '@/components/ui'
import type { QueueService } from '@/lib/data/queue'
import { queueDeskAction, type DeskState } from '@/lib/data/queue-actions'

const INITIAL: DeskState = { status: 'idle', message: '' }
const SCAN_PAUSE_MS = 4000 // after a scan, ignore the same code for a moment so one scan is one look-up
const FRAME_WIDTH = 640

const initials = (name: string) =>
  name
    .split(/[\s,]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase())
    .join('')

// The Registrar's queue desk. 1) The student's rotating QR code is read, by a USB barcode scanner (it types
// the code like a keyboard and presses Enter into the field below) or by the camera of this device.
// 2) The student's card appears: compare it with the ID in hand. 3) Approve issues the ticket; "ID does not
// match" throws the scan away. The camera needs https or localhost; a USB scanner must be a 2D imager that
// can read a phone screen.
export default function QueueScanner({ service }: { service: QueueService }) {
  const [state, formAction, pending] = useActionState(queueDeskAction, INITIAL)
  const [dismissed, setDismissed] = useState(0)
  const [camera, setCamera] = useState<'off' | 'on' | 'denied' | 'unsupported'>('off')
  const videoRef = useRef<HTMLVideoElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const lookupFormRef = useRef<HTMLFormElement>(null)
  const codeRef = useRef<HTMLInputElement>(null)
  const pausedUntil = useRef(0)
  const streamRef = useRef<MediaStream | null>(null)

  const showCard = state.status === 'found' && state.stamp > dismissed

  // Keep the keyboard where the next action is: the Approve button takes focus when a card appears
  // (autoFocus), and the code field gets it back otherwise, so a USB scanner always types into it.
  useEffect(() => {
    if (!showCard) codeRef.current?.focus()
  }, [showCard, state])

  // Frame loop for the camera: about 8 frames a second, each one downscaled and read for a QR code.
  useEffect(() => {
    if (camera !== 'on') return
    let frame = 0
    let last = 0
    const loop = (now: number) => {
      frame = requestAnimationFrame(loop)
      if (now - last < 120) return
      last = now
      const video = videoRef.current
      const canvas = canvasRef.current
      if (!video || !canvas || video.readyState < 2 || video.videoWidth === 0) return
      const scale = FRAME_WIDTH / video.videoWidth
      canvas.width = FRAME_WIDTH
      canvas.height = Math.round(video.videoHeight * scale)
      const ctx = canvas.getContext('2d', { willReadFrequently: true })
      if (!ctx) return
      ctx.drawImage(video, 0, 0, canvas.width, canvas.height)
      const image = ctx.getImageData(0, 0, canvas.width, canvas.height)
      const code = jsQR(image.data, image.width, image.height, { inversionAttempts: 'dontInvert' })
      if (code && code.data.startsWith('CUQ1.') && Date.now() > pausedUntil.current) {
        pausedUntil.current = Date.now() + SCAN_PAUSE_MS
        if (codeRef.current) codeRef.current.value = code.data
        lookupFormRef.current?.requestSubmit()
      }
    }
    frame = requestAnimationFrame(loop)
    return () => cancelAnimationFrame(frame)
  }, [camera])

  // Stop the camera when the page is left.
  useEffect(() => {
    return () => streamRef.current?.getTracks().forEach((t) => t.stop())
  }, [])

  async function startCamera() {
    if (!navigator.mediaDevices?.getUserMedia) {
      setCamera('unsupported')
      return
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false })
      streamRef.current = stream
      if (videoRef.current) {
        videoRef.current.srcObject = stream
        await videoRef.current.play()
      }
      setCamera('on')
    } catch {
      setCamera('denied')
    }
  }

  function stopCamera() {
    streamRef.current?.getTracks().forEach((t) => t.stop())
    streamRef.current = null
    setCamera('off')
  }

  return (
    <Card className="flex flex-col gap-4 p-5">
      <CardHeader title="Queue desk" icon="users" />

      <div role="status" aria-live="polite" aria-busy={pending} className="flex flex-col gap-3">
        {pending && <p className="text-sm text-muted">Checking...</p>}

        {!pending && showCard && state.status === 'found' && (
          <div
            className="flex flex-col gap-4 rounded-xl border border-warm-edge bg-warm-glass p-4"
            onKeyDown={(e) => {
              if (e.key === 'Escape') setDismissed(Date.now())
            }}
          >
            <div className="flex items-center gap-4">
              {/* The student's photo will go here (photo placeholder: initials until a photo exists). */}
              <span
                aria-hidden="true"
                className="grid size-16 shrink-0 place-items-center rounded-2xl bg-gold text-xl font-extrabold text-[#18181b]"
              >
                {initials(state.studentName)}
              </span>
              <div className="min-w-0">
                <p className="truncate text-2xl leading-tight font-bold">{state.studentName}</p>
                <p className="text-sm text-muted tabular-nums">{state.studentNumber}</p>
                <p className="truncate text-sm">
                  {state.programCode} {state.programName && `· ${state.programName}`}
                </p>
              </div>
            </div>
            <p className="text-sm font-medium">Compare this screen with the person and the ID. If it matches, approve.</p>
            {state.alreadyQueuedLabel && (
              <p role="alert" className="rounded-md bg-danger-soft px-3 py-2 text-sm font-medium text-danger">
                This student already has ticket {state.alreadyQueuedLabel} in the queue.
              </p>
            )}
            <div className="flex flex-wrap gap-2">
              <form action={formAction}>
                <input type="hidden" name="service" value={service} />
                <input type="hidden" name="step" value="approve" />
                <input type="hidden" name="studentId" value={state.studentId} />
                <Button type="submit" autoFocus disabled={pending || state.alreadyQueuedLabel !== null}>
                  Approve and issue ticket
                </Button>
              </form>
              <Button variant="outline" onClick={() => setDismissed(Date.now())}>
                ID does not match
              </Button>
            </div>
          </div>
        )}

        {!pending && state.status === 'issued' && (
          <div key={state.stamp} className="rounded-xl border border-warm-edge bg-warm-glass px-4 py-4">
            <p className="text-[13px] font-medium text-muted">Ticket issued</p>
            <p className="text-5xl leading-none font-extrabold tracking-tight tabular-nums">{state.label}</p>
            <p className="mt-2 text-sm">{state.peopleAhead === 0 ? 'Nobody is ahead of this student.' : `${state.peopleAhead} ahead in the line.`}</p>
          </div>
        )}

        {!pending && state.status === 'error' && (
          <p role="alert" className="rounded-md bg-danger-soft px-3 py-2 text-sm font-medium text-danger">
            {state.message}
          </p>
        )}
      </div>

      <form ref={lookupFormRef} action={formAction} className="flex flex-col gap-2 border-t border-border pt-4">
        <input type="hidden" name="service" value={service} />
        <input type="hidden" name="step" value="lookup" />
        <label htmlFor="scan-code" className="text-sm font-medium">
          Scan the student&apos;s code
        </label>
        <div className="flex flex-wrap gap-2">
          <input
            ref={codeRef}
            id="scan-code"
            name="token"
            type="text"
            autoComplete="off"
            autoFocus
            spellCheck={false}
            placeholder="Point the scanner at the phone"
            className="glass h-10 min-w-0 flex-1 rounded-full border border-field-border bg-card px-4 text-sm text-foreground placeholder:text-muted max-lg:h-11"
          />
          <Button type="submit" variant="outline" disabled={pending}>
            Look up
          </Button>
        </div>
        <p className="text-[13px] text-muted">
          A USB barcode scanner types the code here by itself. Keep this field selected. Or use the camera below.
        </p>
      </form>

      <div className="flex flex-col gap-3">
        <div className={camera === 'on' ? 'relative aspect-[4/3] w-full overflow-hidden rounded-xl bg-ink' : 'hidden'}>
          <video ref={videoRef} playsInline muted className="size-full object-cover" />
          <div aria-hidden="true" className="pointer-events-none absolute inset-6 rounded-2xl border-2 border-white/70" />
        </div>
        <canvas ref={canvasRef} className="hidden" />
        {camera === 'denied' && <p className="text-sm text-muted">The camera is blocked. Allow camera access in the browser, or use a scanner.</p>}
        {camera === 'unsupported' && <p className="text-sm text-muted">This browser cannot use the camera here. Use a scanner or type the code.</p>}
        <div>
          {camera === 'on' ? (
            <Button variant="outline" onClick={stopCamera}>
              Stop camera
            </Button>
          ) : (
            <Button variant="outline" onClick={startCamera}>
              Use the camera
            </Button>
          )}
        </div>
      </div>
    </Card>
  )
}
