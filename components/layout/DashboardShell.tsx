import { logout } from '@/app/(auth)/login/actions'
import type { CurrentProfile } from '@/lib/auth/session'
import { getUnreadCount } from '@/lib/data/notifications'
import { NAV_ITEMS } from '@/lib/nav'
import { Icon } from './Icon'
import ShellFrame from './ShellFrame'

// Shared frame for every module page: flat role-based sidebar, optional page header and sign-out.
// Build each module's real UI inside {children}.
export default async function DashboardShell({
  profile,
  title,
  subtitle,
  actions,
  userMeta,
  promo,
  settingsHref,
  variant,
  children,
}: {
  profile: CurrentProfile
  /** Page heading. Leave it out for screens that open with their own first line (the student dashboard). */
  title?: string
  subtitle?: string
  actions?: React.ReactNode
  /** Line under the user's name in the sidebar user row; defaults to the role. */
  userMeta?: string
  /** Accepted for compatibility; the flat shell does not render a sidebar promo. */
  promo?: React.ReactNode
  settingsHref?: string
  /** Defaults to `student` for the Student role and `staff` for every other role (staff adds the role label). */
  variant?: 'student' | 'staff'
  children: React.ReactNode
}) {
  const shell = variant ?? (profile.role === 'Student' ? 'student' : 'staff')
  const unreadCount = await getUnreadCount()
  return (
    <ShellFrame
      items={NAV_ITEMS[profile.role]}
      roleLabel={profile.role}
      userName={`${profile.firstName} ${profile.lastName}`}
      userMeta={userMeta}
      promo={promo}
      settingsHref={settingsHref}
      variant={shell}
      title={title}
      unreadCount={unreadCount}
      signOut={
        <form action={logout}>
          <button className="flex h-10 w-full items-center gap-3 rounded-full px-3 text-sm font-medium text-rail-muted transition-colors max-lg:h-11 hover:bg-rail-hover hover:text-rail-foreground focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rail-ring">
            <span className="flex size-5 shrink-0 items-center justify-center">
              <Icon name="logout" />
            </span>
            Sign out
          </button>
        </form>
      }
    >
      {title && (
        <header className="mb-6 flex flex-wrap items-end justify-between gap-x-4 gap-y-3 lg:mb-8">
          <div className="min-w-0">
            <h1 className="text-2xl font-semibold tracking-[-0.01em]">{title}</h1>
            {subtitle && <p className="mt-1 max-w-[70ch] text-sm text-muted">{subtitle}</p>}
          </div>
          {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
        </header>
      )}
      {children}
    </ShellFrame>
  )
}
