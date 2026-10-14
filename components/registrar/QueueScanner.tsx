'use client'

import { useActionState, useEffect, useRef, useState } from 'react'
import jsQR from 'jsqr'
import { Icon } from '@/components/layout/Icon'
import { Button, Card, CardHeader } from '@/components/ui'
import type { QueueService } from '@/lib/data/queue'
import { queueDeskAction, type DeskState } from '@/lib/data/queue-actions'

const INITIAL: DeskState = { status: 'idle', message: '' }
const RESULT_MS = 7000 // how long a result stays on screen; the camera is locked for the same time (no re-reads)
const FRAME_WIDTH = 640

const initials = (name: string) =>
  name
    .split(/[\s,]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase())
    .join('')

// The Registrar's scan desk. One scan = one ticket: the student's rotating QR code is read by the camera of this
// device or by a USB barcode scanner (it types the code like a keyboard and presses Enter into the field below),
// checked on the server, and the ticket is issued in the same step. The result (who, which number, how many
// ahead) stays on screen for a few seconds while the camera is locked, so one scan can never become two. The
// student's ID is checked against the person at the window, when the number is called. The camera needs https or
// localhost; a USB scanner must be a 2D imager that can read a phone screen.
export default function QueueScanner({ service }: { service: QueueService }) {
  const [state, formAction, pending] = useActionState(queueDeskAction, INITIAL)
  const [hiddenStamp, setHiddenStamp] = useState(0)
  const [camera, setCamera] = useState<'off' | 'on' | 'denied' | 'unsupported'>('off')
  const videoRef = useRef<HTMLVideoElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const formRef = useRef<HTMLFormElement>(null)
  const codeRef = useRef<HTMLInputElement>(null)
  const lockedUntil = useRef(0)
  const pendingRef = useRef(false)
  const streamRef = useRef<MediaStream | null>(null)

  const result = state.status !== 'idle' && state.stamp > hiddenStamp ? state : null

  useEffect(() => {
    pendingRef.current = pending
  }, [pending])

  // After a result: keep it on screen for RESULT_MS, then clear it; lock the camera for the same time; buzz the
  // phone when a ticket was issued.
  useEffect(() => {
    if (state.status === 'idle') return
    lockedUntil.current = Date.now() + RESULT_MS
    const timer = setTimeout(() => setHiddenStamp(state.stamp), RESULT_MS)
    if (state.status === 'issued' && typeof navigator !== 'undefined') navigator.vibrate?.(120)
    return () => clearTimeout(timer)
  }, [state])

  // A USB scanner types into the code field, so keep it selected on a desk (wide screen). Not on a phone: it
  // would open the keyboard over the camera.
  useEffect(() => {
    if (camera !== 'on' && window.matchMedia('(min-width: 1024px)').matches) codeRef.current?.focus()
  }, [camera, state])

  // Frame loop for the camera: about 8 frames a second, each one downscaled and read for a QR code.
  useEffect(() => {
    if (camera !== 'on') return
    let frame = 0
    let last = 0
    const loop = (now: number) => {
      frame = requestAnimationFrame(loop)
      if (now - last < 120) return
      last = now
      if (pendingRef.current || Date.now() < lockedUntil.current) return
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
      if (code && code.data.startsWith('CUQ1.')) {
        lockedUntil.current = Date.now() + RESULT_MS // locked before the answer arrives, so it is read once
        if (codeRef.current) codeRef.current.value = code.data
        formRef.current?.requestSubmit()
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
      <CardHeader title="Scan to issue a ticket" icon="queue" />
      <p className="text-sm leading-6 text-muted">
        Hold the student&apos;s phone up to the camera. The ticket is issued right away. Check the student&apos;s ID when you
        call their number at the window.
      </p>

      {/* The camera, or the button that starts it. */}
      <div className="relative aspect-[4/3] w-full overflow-hidden rounded-2xl bg-ink text-ink-foreground">
        <video ref={videoRef} playsInline muted className={camera === 'on' ? 'size-full object-cover' : 'hidden'} />
        <canvas ref={canvasRef} className="hidden" />
        {camera === 'on' ? (
          <>
            <div aria-hidden="true" className="pointer-events-none absolute inset-6 rounded-3xl border-2 border-white/70" />
            <p className="absolute inset-x-0 bottom-3 text-center text-sm font-semibold drop-shadow">
              {pending ? 'Checking the code...' : result ? 'Done. Ready again in a moment.' : 'Hold the QR code inside the frame'}
            </p>
            <button
              type="button"
              onClick={stopCamera}
              className="absolute top-3 right-3 rounded-full bg-black/55 px-3 py-1.5 text-xs font-semibold text-white focus-visible:outline-2 focus-visible:outline-white"
            >
              Stop camera
            </button>
          </>
        ) : (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 p-6 text-center">
            <span className="grid size-14 place-items-center rounded-full bg-gold text-[#18181b]">
              <Icon name="queue" className="size-6" />
            </span>
            <p className="text-base font-semibold">Camera is off</p>
            <button
              type="button"
              onClick={startCamera}
              className="h-11 rounded-full bg-gold px-6 text-sm font-bold text-[#18181b] transition-colors hover:brightness-95 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-white"
            >
              Start camera
            </button>
            {camera === 'denied' && (
              <p className="max-w-[34ch] text-sm text-white/80">The camera is blocked. Allow camera access in the browser, or use a scanner below.</p>
            )}
            {camera === 'unsupported' && (
              <p className="max-w-[34ch] text-sm text-white/80">This browser cannot use the camera here. Use a scanner or type the code below.</p>
            )}
          </div>
        )}
      </div>

      {/* The answer to the last scan. It keeps its height so the page does not jump. */}
      <div role="status" aria-live="polite" aria-busy={pending} className="min-h-[8.5rem]">
        {pending ? (
          <div className="flex h-[8.5rem] items-center justify-center rounded-2xl border border-dashed border-field-border text-sm text-muted">
            Checking the code...
          </div>
        ) : result?.status === 'issued' ? (
          <div key={result.stamp} className="flex flex-col gap-3 rounded-2xl bg-ink p-4 text-ink-foreground shadow-elev-md">
            <div className="flex items-center justify-between gap-3">
              <p className="flex items-center gap-1.5 text-[13px] font-semibold tracking-wide text-gold uppercase">
                <Icon name="check" className="size-4" /> Ticket issued
              </p>
              <p className="rounded-full bg-white/10 px-3 py-1 text-xs font-semibold">
                {result.peopleAhead === 0 ? 'Next in line' : `${result.peopleAhead} ahead`}
              </p>
            </div>
            <p className="text-5xl leading-none font-extrabold tracking-tight text-gold tabular-nums">{result.label}</p>
            <div className="flex items-center gap-3">
              <span aria-hidden="true" className="grid size-10 shrink-0 place-items-center rounded-xl bg-gold text-sm font-extrabold text-[#18181b]">
                {initials(result.studentName)}
              </span>
              <div className="min-w-0">
                <p className="truncate text-base font-semibold">{result.studentName}</p>
                <p className="truncate text-[13px] text-white/75 tabular-nums">
                  {result.studentNumber} · {result.programCode}
                </p>
              </div>
            </div>
          </div>
        ) : result?.status === 'duplicate' ? (
          <div key={result.stamp} className="flex flex-col gap-1 rounded-2xl border border-warm-edge bg-warm-glass p-4">
            <p className="text-[13px] font-semibold tracking-wide text-muted uppercase">Already in line</p>
            <p className="text-3xl leading-none font-extrabold tracking-tight tabular-nums">{result.label ?? '-'}</p>
            <p className="mt-1 text-sm">
              <span className="font-semibold">{result.studentName}</span> ({result.studentNumber}) already has a ticket in this
              line. No new ticket was issued.
            </p>
          </div>
        ) : result?.status === 'error' ? (
          <div key={result.stamp} role="alert" className="rounded-2xl bg-danger-soft p-4 text-danger">
            <p className="text-[13px] font-semibold tracking-wide uppercase">Not issued</p>
            <p className="mt-1 text-sm font-medium">{result.message}</p>
          </div>
        ) : (
          <div className="flex h-[8.5rem] flex-col items-center justify-center gap-1 rounded-2xl border border-dashed border-field-border px-4 text-center">
            <p className="text-sm font-semibold">Ready for the next student</p>
            <p className="text-[13px] text-muted">The ticket number and the student&apos;s name appear here after a scan.</p>
          </div>
        )}
      </div>

      {/* USB barcode scanner or typed code: the same step as the camera. */}
      <form ref={formRef} action={formAction} className="flex flex-col gap-2 border-t border-border pt-4">
        <input type="hidden" name="service" value={service} />
        <label htmlFor="scan-code" className="text-sm font-medium">
          Using a barcode scanner? Scan here
        </label>
        <div className="flex flex-wrap gap-2">
          <input
            ref={codeRef}
            id="scan-code"
            name="token"
            type="text"
            autoComplete="off"
            spellCheck={false}
            placeholder="The scanner types the code here"
            className="glass h-10 min-w-0 flex-1 rounded-full border border-field-border bg-card px-4 text-sm text-foreground placeholder:text-muted max-lg:h-11"
          />
          <Button type="submit" variant="outline" disabled={pending}>
            Issue ticket
          </Button>
        </div>
        <p className="text-[13px] text-muted">A USB scanner presses Enter by itself. Keep this field selected on a desk computer.</p>
      </form>
    </Card>
  )
}
