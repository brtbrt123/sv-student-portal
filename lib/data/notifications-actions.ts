'use server'

import { revalidatePath } from 'next/cache'
import { getCurrentProfile } from '@/lib/auth/session'
import { getUnreadCount, notificationRpc } from '@/lib/data/notifications'

// Server Actions for the notification inbox. They run with the signed-in user's own session; the database
// functions only ever touch the caller's own rows.

export type MarkReadResult = { status: 'ok'; changed: number } | { status: 'error'; message: string }

const MAX_IDS = 100

// Marks the given notifications (or all of them, when no ids are given) as read.
export async function markNotificationsRead(ids?: number[]): Promise<MarkReadResult> {
  try {
    const profile = await getCurrentProfile()
    if (!profile) return { status: 'error', message: 'Your session has ended. Please sign in again.' }

    let p_ids: number[] | null = null
    if (ids !== undefined) {
      const clean = [...new Set(ids)].filter((n) => Number.isSafeInteger(n) && n > 0).slice(0, MAX_IDS)
      if (clean.length === 0) return { status: 'ok', changed: 0 }
      p_ids = clean
    }

    const rpc = await notificationRpc()
    const { data, error } = await rpc<number>('mark_notifications_read', { p_ids })
    if (error) return { status: 'error', message: 'We could not update your notifications. Please try again.' }
    revalidatePath('/', 'layout')
    return { status: 'ok', changed: typeof data === 'number' ? data : 0 }
  } catch {
    return { status: 'error', message: 'We could not update your notifications. Please try again.' }
  }
}

// The unread count, for the badge to refresh itself. No profile check here on purpose: the database function
// refuses a signed-out or deactivated account (getUnreadCount then returns 0), and a check in front of it
// would add two database round trips to every poll.
export async function fetchUnreadCount(): Promise<number> {
  return getUnreadCount()
}
