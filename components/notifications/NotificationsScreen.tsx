import DashboardShell from '@/components/layout/DashboardShell'
import { AutoRefresh } from '@/components/queue/AutoRefresh'
import { EmptyState } from '@/components/ui'
import type { RoleName } from '@/lib/auth/roles'
import { requireRole } from '@/lib/auth/session'
import { listMyNotifications } from '@/lib/data/notifications'
import { kindIcon } from '@/lib/notifications/kind'
import { formatWhen } from '@/lib/notifications/time'
import NotificationList from './NotificationList'

// The notifications page of one role: the same screen for all five roles (each role has its own route under
// its own module, so the role check and the sidebar stay as they are).
export default async function NotificationsScreen({ role }: { role: RoleName }) {
  const profile = await requireRole(role)
  const items = await listMyNotifications(50)
  const now = new Date()

  return (
    <DashboardShell profile={profile} title="Notifications" subtitle="Everything that changed for you, newest first">
      <AutoRefresh everySeconds={20} />
      {items === null ? (
        <div role="alert">
          <EmptyState title="We could not load your notifications">
            Something went wrong on our side. Reload the page, and if it keeps happening, come back in a few minutes.
          </EmptyState>
        </div>
      ) : (
        <NotificationList
          items={items.map((n) => ({
            id: n.id,
            title: n.title,
            body: n.body,
            link: n.link,
            unread: n.readAt === null,
            when: formatWhen(n.createdAt, now),
            icon: kindIcon(n.kind),
          }))}
        />
      )}
    </DashboardShell>
  )
}
