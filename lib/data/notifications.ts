import { createClient } from '@/lib/supabase/server'

// Server-side reads for the notification inbox. Every call runs with the signed-in user's own session and
// goes through the database functions of docs/database/notifications_rules.sql, which only ever return the
// caller's own notifications. The functions are not in types/database.types.ts, so the calls go through a
// local cast (same as lib/data/queue.ts). Import from Server Components and Server Actions only.

type RpcResult<T> = PromiseLike<{ data: T | null; error: { code?: string; message?: string } | null }>
type Rpc = <T>(fn: string, args?: Record<string, unknown>) => RpcResult<T>

async function rpcOfUser(): Promise<Rpc> {
  const supabase = await createClient()
  return supabase.rpc.bind(supabase) as unknown as Rpc
}

export type AppNotification = {
  id: number
  kind: string
  title: string
  body: string
  /** An in-app path such as /student/documents, or null. */
  link: string | null
  createdAt: string
  readAt: string | null
}

type Row = {
  notification_id: number
  kind: string
  title: string
  body: string | null
  link: string | null
  created_at: string
  read_at: string | null
}

// The caller's newest notifications. Null when the call fails, so the page can say so; never throws.
export async function listMyNotifications(limit = 50): Promise<AppNotification[] | null> {
  try {
    const rpc = await rpcOfUser()
    const { data, error } = await rpc<Row[]>('list_my_notifications', { p_limit: limit, p_unread_only: false })
    if (error || !Array.isArray(data)) return null
    return data.map((r) => ({
      id: Number(r.notification_id),
      kind: r.kind,
      title: r.title,
      body: r.body ?? '',
      link: r.link,
      createdAt: r.created_at,
      readAt: r.read_at,
    }))
  } catch {
    return null
  }
}

// The unread count for the badge. 0 when anything goes wrong: a missing badge is better than a broken page.
export async function getUnreadCount(): Promise<number> {
  try {
    const rpc = await rpcOfUser()
    const { data, error } = await rpc<number>('notification_unread_count')
    if (error || typeof data !== 'number' || !Number.isFinite(data)) return 0
    return Math.max(0, Math.floor(data))
  } catch {
    return 0
  }
}

export { rpcOfUser as notificationRpc }
