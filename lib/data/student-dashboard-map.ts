// Pure helpers for the Student dashboard (no database, no server-only imports, so unit tests and
// client components can use them). The schedule is free text in sections.schedule, for example
// "MWF 8:00-9:00" or "TTh 9-10:30 AM"; a schedule we cannot read is left out of "next class".

export type Meeting = { days: number[]; startMin: number; endMin: number }

const DAY_TOKENS: [string, number][] = [
  ['TH', 4],
  ['SA', 6],
  ['SU', 0],
  ['M', 1],
  ['T', 2],
  ['W', 3],
  ['F', 5],
]

function parseDays(text: string): number[] | null {
  const days: number[] = []
  let rest = text
  while (rest.length) {
    const hit = DAY_TOKENS.find(([t]) => rest.startsWith(t))
    if (!hit) return null
    days.push(hit[1])
    rest = rest.slice(hit[0].length)
  }
  return days.length ? days : null
}

// Class hours without AM/PM follow the campus day: 7 to 11 is morning, 12 and 1 to 6 are afternoon.
function toMinutes(h: number, m: number, meridiem: string | null): number {
  let hour = h
  if (meridiem === 'PM' && h < 12) hour = h + 12
  else if (meridiem === 'AM' && h === 12) hour = 0
  else if (!meridiem && h >= 1 && h <= 6) hour = h + 12
  return hour * 60 + m
}

export function parseSchedule(text: string | null): Meeting | null {
  if (!text) return null
  const match = text.trim().match(/^([A-Za-z]+)\s+(\d{1,2})(?::(\d{2}))?\s*(AM|PM)?\s*-\s*(\d{1,2})(?::(\d{2}))?\s*(AM|PM)?$/i)
  if (!match) return null
  const days = parseDays(match[1].toUpperCase())
  if (!days) return null
  const startMer = match[4]?.toUpperCase() ?? null
  const endMer = match[7]?.toUpperCase() ?? null
  const endMin = toMinutes(Number(match[5]), Number(match[6] ?? 0), endMer)
  let startMin = toMinutes(Number(match[2]), Number(match[3] ?? 0), startMer ?? endMer)
  if (!startMer && endMer && startMin >= endMin) startMin = toMinutes(Number(match[2]), Number(match[3] ?? 0), null)
  if (endMin <= startMin) return null
  return { days, startMin, endMin }
}

export function formatClock(minutes: number): string {
  const h24 = Math.floor(minutes / 60) % 24
  const m = minutes % 60
  const h12 = h24 % 12 === 0 ? 12 : h24 % 12
  return `${h12}:${String(m).padStart(2, '0')} ${h24 < 12 ? 'AM' : 'PM'}`
}

export type NowParts = { weekday: number; minutes: number; seconds: number }

/** Seconds from `now` until the meeting next starts (a class that already started today counts for next week). */
export function secondsUntilStart(meeting: Meeting, now: NowParts): number {
  let best = Infinity
  for (const day of meeting.days) {
    let ahead = (day - now.weekday + 7) % 7
    let diff = ahead * 86400 + meeting.startMin * 60 - (now.minutes * 60 + now.seconds)
    if (diff <= 0) {
      ahead += 7
      diff += 7 * 86400
    }
    best = Math.min(best, diff)
  }
  return best
}

export type ScheduleClass = { code: string; title: string; schedule: string | null }

export function pickNextClass(classes: ScheduleClass[], now: NowParts) {
  let best: { code: string; title: string; startsAt: string; seconds: number } | null = null
  for (const c of classes) {
    const meeting = parseSchedule(c.schedule)
    if (!meeting) continue
    const seconds = secondsUntilStart(meeting, now)
    if (!best || seconds < best.seconds) {
      best = { code: c.code, title: c.title, startsAt: formatClock(meeting.startMin), seconds }
    }
  }
  return best
}

/** "S1 25" for 1st Semester 2025-2026: short enough to sit under a bar on a phone. */
export function shortTermLabel(semester: string, schoolYear: string): string {
  const digit = semester.match(/\d/)?.[0]
  const yy = schoolYear.match(/\d{4}/)?.[0]?.slice(2)
  return `${digit ? `S${digit}` : semester.slice(0, 3)}${yy ? ` ${yy}` : ''}`
}

export const GWA_CHART_CEILING = 3.25

export function gwaYTicks(values: number[]): number[] {
  return Math.max(...values, 0) > 3 ? [1, 2, 3, 4, 5] : [1, 1.5, 2, 2.5, 3]
}

/** Bar height: distance below the ceiling, so the best (lowest) GWA is the tallest bar. Kept above zero. */
export function gwaBarValue(gwa: number): number {
  return Math.min(1.5, Math.max(0.05, GWA_CHART_CEILING - gwa))
}
