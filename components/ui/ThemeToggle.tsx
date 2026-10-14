'use client'

import { useLayoutEffect, useSyncExternalStore } from 'react'
import { cn } from '@/lib/utils'

type Theme = 'light' | 'dark'

const STORAGE_KEY = 'theme'
const CHANGE_EVENT = 'themechange'

// The theme lives in the data-theme attribute on <html>; an inline script in app/layout.tsx
// sets it before the first paint. This button flips it and remembers the choice.
function readPreferred(): Theme {
  try {
    const stored = localStorage.getItem(STORAGE_KEY)
    if (stored === 'light' || stored === 'dark') return stored
  } catch {}
  return matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

function subscribe(onChange: () => void) {
  window.addEventListener(CHANGE_EVENT, onChange)
  window.addEventListener('storage', onChange)
  return () => {
    window.removeEventListener(CHANGE_EVENT, onChange)
    window.removeEventListener('storage', onChange)
  }
}

function getSnapshot(): Theme | null {
  const value = document.documentElement.getAttribute('data-theme')
  return value === 'light' || value === 'dark' ? value : null
}

function apply(theme: Theme) {
  document.documentElement.setAttribute('data-theme', theme)
  window.dispatchEvent(new Event(CHANGE_EVENT))
}

export function ThemeToggle({ className }: { className?: string }) {
  const theme = useSyncExternalStore(subscribe, getSnapshot, () => null)

  // React's dev-mode remount can clear the attribute the inline script set; put it back.
  useLayoutEffect(() => {
    if (getSnapshot() === null) apply(readPreferred())
  }, [])

  function toggle() {
    const next: Theme = (theme ?? readPreferred()) === 'dark' ? 'light' : 'dark'
    try {
      localStorage.setItem(STORAGE_KEY, next)
    } catch {}
    apply(next)
  }

  return (
    <button
      type="button"
      onClick={toggle}
      aria-label={theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'}
      className={cn(
        'inline-flex size-9 max-lg:size-11 shrink-0 items-center justify-center rounded-full text-muted transition-colors hover:bg-hover-tint hover:text-foreground',
        'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring',
        className
      )}
    >
      {/* Shows what you will switch to: a moon in light mode, a sun in dark mode. */}
      <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" className="size-[18px] dark:hidden">
        <path
          d="M20.5 14.2A8.5 8.5 0 0 1 9.8 3.5a8.5 8.5 0 1 0 10.7 10.7Z"
          stroke="currentColor"
          strokeWidth="1.8"
          strokeLinejoin="round"
        />
      </svg>
      <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" className="hidden size-[18px] dark:block">
        <circle cx="12" cy="12" r="4" stroke="currentColor" strokeWidth="1.8" />
        <path
          d="M12 2.5v2.2M12 19.3v2.2M4.9 4.9l1.6 1.6M17.5 17.5l1.6 1.6M2.5 12h2.2M19.3 12h2.2M4.9 19.1l1.6-1.6M17.5 6.5l1.6-1.6"
          stroke="currentColor"
          strokeWidth="1.8"
          strokeLinecap="round"
        />
      </svg>
    </button>
  )
}
