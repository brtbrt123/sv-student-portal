// Pure helpers for the student's place in the line: how long to wait and which positions to draw.

// The Registrar's rough time per applicant at the window (PM decision 2026-10-13: 3 to 5 minutes each).
export const MINUTES_PER_PERSON = { min: 3, max: 5 } as const

export type WaitRange = { min: number; max: number }

// The wait before it is your turn: people ahead times 3 to 5 minutes. Null when nobody is ahead.
export function estimateWait(peopleAhead: number): WaitRange | null {
  if (!Number.isFinite(peopleAhead) || peopleAhead <= 0) return null
  return { min: peopleAhead * MINUTES_PER_PERSON.min, max: peopleAhead * MINUTES_PER_PERSON.max }
}

// "6-10 min" with an en dash, or "5 min" when both ends are equal.
export function formatWait(range: WaitRange): string {
  return range.min === range.max ? `${range.min} min` : `${range.min}–${range.max} min`
}

export type LineSlot = { kind: 'ahead' | 'you' | 'behind' | 'gap'; position?: number }

// The positions to draw as a line: the ones ahead of you, you, and the ones behind. A long line is
// shortened with a gap. `position` is 1-based (peopleAhead + 1); `waitingTotal` counts everybody waiting.
export function lineSlots(position: number, waitingTotal: number, maxShown = 7): LineSlot[] {
  const me = Math.max(1, Math.floor(position))
  const total = Math.max(me, Math.floor(waitingTotal))
  const slot = (n: number): LineSlot => ({ kind: n < me ? 'ahead' : n === me ? 'you' : 'behind', position: n })

  if (total <= maxShown) return Array.from({ length: total }, (_, i) => slot(i + 1))

  if (me <= maxShown - 1) {
    return [...Array.from({ length: maxShown - 1 }, (_, i) => slot(i + 1)), { kind: 'gap' }]
  }

  // Far back in the line: the first three, a gap, then you.
  return [slot(1), slot(2), slot(3), { kind: 'gap' }, slot(me)]
}

/** A ticket still in the line: waiting, on hold, or being served. */
export const isActiveTicketStatus = (status: string | null | undefined): boolean =>
  status === 'Waiting' || status === 'Held' || status === 'Serving'

// A student needs a NEW queue number only for something that happened after their last finished (Done) ticket in
// that line: a request filed or moved on (Processing, Ready), an enrollment submitted. What was already there when
// they were served is handled. `eventTimes` are ISO times of the open items; `lastServedAt` is the finish time of
// their last Done ticket in the line, null when they were never served. A closed (Cancelled) or missed (No-show)
// ticket is not a service, so it does not count here and the code comes back for the same item.
export function needsNewNumber(eventTimes: readonly (string | null)[], lastServedAt: string | null): boolean {
  const open = eventTimes.filter((t): t is string => typeof t === 'string' && !Number.isNaN(Date.parse(t)))
  if (open.length === 0) return false
  if (lastServedAt === null || Number.isNaN(Date.parse(lastServedAt))) return true
  const served = Date.parse(lastServedAt)
  return open.some((t) => Date.parse(t) > served)
}
