'use client'

import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useTransition } from 'react'
import { Icon } from '@/components/layout/Icon'
import { Button, Card, EmptyState } from '@/components/ui'
import type { IconName } from '@/lib/nav'
import { markNotificationsRead } from '@/lib/data/notifications-actions'
import { cn } from '@/lib/utils'

export type NotificationRow = {
  id: number
  title: string
  body: string
  link: string | null
  unread: boolean
  /** Already formatted on the server ("5 min ago"), so the server and the browser never disagree. */
  when: string
  icon: IconName
}

// The inbox: newest first, unread ones marked. Opening a notification marks it read and goes to its page.
export default function NotificationList({ items }: { items: NotificationRow[] }) {
  const router = useRouter()
  const [pending, startTransition] = useTransition()
  const unread = items.filter((n) => n.unread).length

  function markAll() {
    startTransition(async () => {
      await markNotificationsRead()
      router.refresh()
    })
  }

  function open(n: NotificationRow) {
    if (n.unread) {
      startTransition(async () => {
        await markNotificationsRead([n.id])
        router.refresh()
      })
    }
  }

  if (items.length === 0) {
    return (
      <EmptyState title="No notifications yet">
        When something changes for you, such as your place in the queue or a decision on a request, it shows up here.
      </EmptyState>
    )
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p role="status" className="text-sm font-medium text-muted">
          {unread === 0 ? 'You are all caught up.' : `${unread} unread`}
        </p>
        <Button variant="outline" onClick={markAll} disabled={pending || unread === 0} aria-busy={pending}>
          Mark all as read
        </Button>
      </div>

      <Card elevation="flat" className="overflow-hidden p-0">
        <ul className="flex flex-col divide-y divide-border">
          {items.map((n) => {
            const body = (
              <>
                <span
                  aria-hidden="true"
                  className={cn(
                    'grid size-10 shrink-0 place-items-center rounded-full',
                    n.unread ? 'bg-gold text-[#18181b]' : 'bg-hover-tint text-muted'
                  )}
                >
                  <Icon name={n.icon} className="size-[18px]" />
                </span>
                <span className="min-w-0 flex-1">
                  <span className="flex flex-wrap items-baseline justify-between gap-x-3">
                    <span className={cn('text-sm', n.unread ? 'font-bold' : 'font-medium')}>
                      {n.unread && <span className="sr-only">Unread: </span>}
                      {n.title}
                    </span>
                    <span className="shrink-0 text-xs text-muted">{n.when}</span>
                  </span>
                  {n.body && <span className="mt-0.5 block text-sm leading-6 text-muted">{n.body}</span>}
                </span>
                {n.unread && <span aria-hidden="true" className="mt-2 size-2.5 shrink-0 rounded-full bg-gold ring-2 ring-gold/30" />}
              </>
            )
            const rowClass = cn(
              'flex w-full items-start gap-3 px-4 py-3.5 text-left transition-colors hover:bg-hover-tint focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-ring',
              n.unread && 'bg-warm-glass'
            )
            return (
              <li key={n.id}>
                {n.link ? (
                  <Link href={n.link} onClick={() => open(n)} className={rowClass}>
                    {body}
                  </Link>
                ) : (
                  <button type="button" onClick={() => open(n)} className={rowClass}>
                    {body}
                  </button>
                )}
              </li>
            )
          })}
        </ul>
      </Card>
    </div>
  )
}
