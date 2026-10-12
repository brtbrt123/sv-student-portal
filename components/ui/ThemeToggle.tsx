'use client'

import { useLayoutEffect, useSyncExternalStore } from 'react'
import { cn } from '@/lib/utils'

type Theme = 'light' | 'dark'

const STORAGE_KEY = 'theme'
const CHANGE_EVENT = 'themechange'

// The theme lives in the data-theme attribute on <html>; an inline script in app/layout.tsx
// sets it before the first paint. This switch (sun, track, moon) flips it and remembers the choice.
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

  const isDark = theme === 'dark'

  return (
    <div className={cn('inline-flex shrink-0 items-center gap-2 text-muted', className)}>
      <SunIcon className="size-[18px]" />
      <button
        type="button"
        role="switch"
        aria-checked={isDark}
        aria-label="Dark mode"
        onClick={toggle}
        className={cn(
          'relative h-7 w-14 shrink-0 cursor-pointer rounded-full border border-field-border bg-track',
          'shadow-[inset_0_2px_4px_rgb(26_25_35/0.18)] dark:shadow-[inset_0_2px_4px_rgb(0_0_0/0.5)]',
          'transition-colors before:absolute before:-inset-2 before:content-[\'\']',
          'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring'
        )}
      >
        {/* The knob rests on the left in light mode and slides right in dark mode. The dark: variant
            reads data-theme, so the first paint is already correct and nothing animates on load. */}
        <span
          aria-hidden="true"
          className={cn(
            'absolute left-[3px] top-[3px] size-5 rounded-full border border-edge bg-card-raised',
            'shadow-[0_1px_3px_rgb(26_25_35/0.35)] transition-transform duration-200 ease-out motion-reduce:transition-none',
            'dark:translate-x-7 dark:border-transparent dark:bg-muted dark:shadow-[0_1px_3px_rgb(0_0_0/0.6)]'
          )}
        />
      </button>
      <MoonIcon className="size-[18px]" />
    </div>
  )
}

function SunIcon({ className }: { className?: string }) {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" className={className}>
      <circle cx="12" cy="12" r="4" stroke="currentColor" strokeWidth="1.8" />
      <path
        d="M12 2.5v2.2M12 19.3v2.2M4.9 4.9l1.6 1.6M17.5 17.5l1.6 1.6M2.5 12h2.2M19.3 12h2.2M4.9 19.1l1.6-1.6M17.5 6.5l1.6-1.6"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
      />
    </svg>
  )
}

function MoonIcon({ className }: { className?: string }) {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" className={className}>
      <path
        d="M20.5 14.2A8.5 8.5 0 0 1 9.8 3.5a8.5 8.5 0 1 0 10.7 10.7Z"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinejoin="round"
      />
    </svg>
  )
}
