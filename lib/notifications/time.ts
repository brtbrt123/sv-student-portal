// Pure helpers for the notification list. Times are shown in Philippine time, like the rest of the portal.

const MANILA = 'Asia/Manila'
const MINUTE = 60_000
const HOUR = 3_600_000
const DAY = 86_400_000

const dayKey = (d: Date) => d.toLocaleDateString('en-CA', { timeZone: MANILA }) // 2026-10-13
const clock = (d: Date) => d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: MANILA })

// "Just now", "5 min ago", "2 h ago", "Today, 3:05 PM", "Yesterday, 3:05 PM", "Oct 12, 3:05 PM", or with the
// year when it is another year. Empty text for an invalid date.
export function formatWhen(iso: string, now: Date = new Date()): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  const diff = now.getTime() - d.getTime()
  if (diff < MINUTE) return 'Just now' // also a time a little in the future (clock differences)
  if (diff < HOUR) return `${Math.floor(diff / MINUTE)} min ago`
  if (diff < 6 * HOUR) return `${Math.floor(diff / HOUR)} h ago`
  if (dayKey(d) === dayKey(now)) return `Today, ${clock(d)}`
  if (dayKey(d) === dayKey(new Date(now.getTime() - DAY))) return `Yesterday, ${clock(d)}`
  const sameYear = dayKey(d).slice(0, 4) === dayKey(now).slice(0, 4)
  const date = d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', ...(sameYear ? {} : { year: 'numeric' }), timeZone: MANILA })
  return `${date}, ${clock(d)}`
}

// The number on the bell and the menu: nothing for 0, "99+" from 100.
export function unreadLabel(count: number): string {
  if (!Number.isFinite(count) || count <= 0) return ''
  return count > 99 ? '99+' : String(Math.floor(count))
}
