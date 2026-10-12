'use client'

import Image from 'next/image'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useEffect, useRef, useState } from 'react'
import { cn } from '@/lib/utils'
import type { NavItem } from '@/lib/nav'
import { ThemeToggle } from '@/components/ui/ThemeToggle'
import { Icon } from './Icon'

const FOCUS = 'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring'
// Nav rows: 40px on desktop, 44px touch targets below lg; 6px corners; 20px icon column.
const NAV_ITEM = `flex h-10 w-full items-center gap-3 rounded-md px-2.5 text-sm transition-colors max-lg:h-11 ${FOCUS}`
const NAV_ACTIVE = 'bg-accent font-semibold text-accent-foreground'
const NAV_IDLE = 'font-medium text-muted hover:bg-hover-tint hover:text-foreground'
const ICON_BUTTON = `inline-flex size-11 items-center justify-center rounded-md text-muted transition-colors hover:bg-hover-tint hover:text-foreground ${FOCUS}`

// Client half of the shell: flat sidebar (fixed, full height, one hairline on its right edge), the
// mobile drawer and the slim mobile top bar. The server half (DashboardShell) passes plain data plus
// the sign-out form. Student and staff render the same flat shell; staff also shows the role label.
export default function ShellFrame({
  items,
  roleLabel,
  userName,
  userMeta,
  signOut,
  settingsHref,
  variant = 'student',
  title,
  children,
}: {
  items: NavItem[]
  roleLabel: string
  userName: string
  /** Second line under the name in the user row (for example "ID 2026-0001"). Defaults to the role. */
  userMeta?: string
  signOut: React.ReactNode
  /** Accepted for compatibility; the flat shell has no sidebar promo. */
  promo?: React.ReactNode
  /** Where Settings goes. Without it the item is shown but disabled (there is no settings page yet). */
  settingsHref?: string
  /** `staff` adds the role label under the logo; otherwise identical. */
  variant?: 'student' | 'staff'
  /** Page title, shown in the mobile top bar (the logo name when absent). */
  title?: string
  children: React.ReactNode
}) {
  const staff = variant === 'staff'
  const pathname = usePathname()
  const [open, setOpen] = useState(false)
  const homeHref = items[0].href
  const menuRef = useRef<HTMLButtonElement>(null)
  const drawerRef = useRef<HTMLElement>(null)
  const wasOpen = useRef(false)

  // Mobile drawer: Escape closes it, focus moves in when it opens and back to the menu button when it closes.
  useEffect(() => {
    if (open) {
      wasOpen.current = true
      drawerRef.current?.querySelector<HTMLElement>('a[href], button:not([aria-disabled])')?.focus()
      const onKey = (e: KeyboardEvent) => {
        if (e.key === 'Escape') setOpen(false)
      }
      document.addEventListener('keydown', onKey)
      return () => document.removeEventListener('keydown', onKey)
    }
    if (wasOpen.current) {
      wasOpen.current = false
      menuRef.current?.focus()
    }
  }, [open])

  const isActive = (href: string) =>
    href === homeHref ? pathname === href : pathname === href || pathname.startsWith(href + '/')

  return (
    <div className="min-h-screen bg-background text-foreground lg:pl-60">
      <a
        href="#main"
        inert={open}
        className={cn(
          'sr-only rounded-md bg-card px-4 py-2 text-sm font-semibold text-foreground focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-50 focus:border focus:border-border focus:shadow-elev-lg',
          'focus:outline-2 focus:outline-offset-2 focus:outline-ring'
        )}
      >
        Skip to main content
      </a>
      {open && (
        <button
          type="button"
          aria-label="Close menu"
          tabIndex={-1}
          onClick={() => setOpen(false)}
          className="fixed inset-0 z-30 bg-black/40 lg:hidden"
        />
      )}

      <aside
        ref={drawerRef}
        aria-label="Sidebar"
        className={cn(
          'fixed inset-y-0 left-0 z-40 flex w-60 flex-col overflow-y-auto border-r border-border bg-background px-3 pb-3',
          // Desktop: always in place, flat. Phone: a drawer with the one real shadow in the system.
          'shadow-elev-lg lg:translate-x-0 lg:shadow-none',
          // Closed on a phone: off screen and out of the Tab order (visibility switches after the slide).
          // Opening skips the visibility transition so the first link can take focus at once.
          open
            ? 'translate-x-0 transition-transform duration-200 ease-out motion-reduce:transition-none'
            : 'max-lg:invisible max-lg:-translate-x-full max-lg:transition-[transform,visibility] max-lg:duration-200 motion-reduce:transition-none'
        )}
      >
        <div className="flex h-16 shrink-0 items-center gap-2.5 px-2.5">
          <LogoMark />
          <div className="min-w-0 leading-tight">
            <p className="truncate text-sm font-semibold">Cabuyao University</p>
            {staff && <p className="truncate text-xs text-muted">{roleLabel}</p>}
          </div>
        </div>

        <nav aria-label="Main" className="mt-2 flex flex-col gap-0.5">
          {items.map((item) => {
            const active = isActive(item.href)
            return (
              <Link
                key={item.href}
                href={item.href}
                onClick={() => setOpen(false)}
                aria-current={active ? 'page' : undefined}
                className={cn(NAV_ITEM, active ? NAV_ACTIVE : NAV_IDLE)}
              >
                <span className="flex size-5 shrink-0 items-center justify-center">
                  <Icon name={item.icon} />
                </span>
                {item.label}
              </Link>
            )
          })}
        </nav>

        <div className="mt-auto flex flex-col gap-0.5 pt-6">
          {settingsHref ? (
            <Link href={settingsHref} onClick={() => setOpen(false)} className={cn(NAV_ITEM, NAV_IDLE)}>
              <span className="flex size-5 shrink-0 items-center justify-center">
                <Icon name="settings" />
              </span>
              Settings
            </Link>
          ) : (
            <button type="button" aria-disabled="true" className={cn(NAV_ITEM, 'cursor-not-allowed font-medium text-muted')}>
              <span className="flex size-5 shrink-0 items-center justify-center">
                <Icon name="settings" />
              </span>
              Settings
              <span className="ml-auto text-xs font-medium">Soon</span>
            </button>
          )}
          {signOut}

          <div className="mt-2 flex justify-center border-t border-border px-1 pt-3">
            <ThemeToggle />
          </div>
          <div className="mt-3 flex items-center gap-2.5 px-1">
            <span
              aria-hidden="true"
              className="flex size-8 shrink-0 items-center justify-center rounded-full bg-accent text-sm font-semibold text-accent-foreground"
            >
              {userName.charAt(0)}
            </span>
            <div className="min-w-0 flex-1 leading-tight">
              <p className="truncate text-sm font-semibold">{userName}</p>
              <p className="truncate text-xs text-muted">{userMeta ?? roleLabel}</p>
            </div>
          </div>
        </div>
      </aside>

      <div inert={open} className="flex min-h-screen min-w-0 flex-col">
        {/* Below lg only: slim sticky bar with the menu button, the page title and the theme toggle. */}
        <header className="sticky top-0 z-20 flex h-14 shrink-0 items-center gap-1 border-b border-border bg-background px-1.5 lg:hidden">
          <button type="button" ref={menuRef} aria-label="Open menu" onClick={() => setOpen(true)} className={ICON_BUTTON}>
            <Icon name="menu" className="size-5" />
          </button>
          <div className="flex min-w-0 flex-1 items-center gap-2">
            {!title && <LogoMark small />}
            <p className="truncate text-base font-semibold">{title ?? 'Cabuyao University'}</p>
          </div>
          <ThemeToggle />
        </header>
        <main
          id="main"
          tabIndex={-1}
          className="mx-auto flex w-full max-w-[1200px] min-w-0 flex-1 flex-col px-4 py-5 outline-none sm:px-6 lg:px-8 lg:py-8"
        >
          {children}
        </main>
      </div>
    </div>
  )
}

// Cabuyao CU monogram: Figma's own vector (public/brand), same files as the login logo. Never redrawn.
function LogoMark({ small = false }: { small?: boolean }) {
  const size = small ? 'w-7' : 'w-9'
  return (
    <>
      <Image
        src="/brand/cu-mark-light.svg"
        alt=""
        aria-hidden="true"
        width={82}
        height={77}
        unoptimized
        loading="eager"
        className={cn('h-auto shrink-0 dark:hidden', size)}
      />
      <Image
        src="/brand/cu-mark-dark.svg"
        alt=""
        aria-hidden="true"
        width={82}
        height={77}
        unoptimized
        loading="eager"
        className={cn('hidden h-auto shrink-0 dark:block', size)}
      />
    </>
  )
}
