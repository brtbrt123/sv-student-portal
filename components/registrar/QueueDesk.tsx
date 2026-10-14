'use client'

import { useId, useState, type ReactNode } from 'react'
import { cn } from '@/lib/utils'

// The Registrar's queue page. From lg up the scan desk and the line sit side by side. On a phone they
// are two tabs, "Scan" and "Line", so the Registrar does not have to scroll past the camera to reach
// Call next. Both panels stay mounted (hidden with CSS), so a running camera and a scanned card survive
// a switch of tab.
export default function QueueDesk({
  scanner,
  line,
  waitingCount,
  servingCount,
}: {
  scanner: ReactNode
  line: ReactNode
  waitingCount: number
  servingCount: number
}) {
  const [tab, setTab] = useState<'scan' | 'line'>('scan')
  const id = useId()

  const tabs = [
    { key: 'scan', label: 'Scan', hint: null },
    {
      key: 'line',
      label: 'Line',
      hint: servingCount > 0 ? `${waitingCount} waiting, ${servingCount} at the window` : `${waitingCount} waiting`,
    },
  ] as const

  return (
    <div className="flex flex-col gap-4">
      <div role="tablist" aria-label="Queue desk" className="glass grid grid-cols-2 gap-1 rounded-full border border-border bg-card p-1 lg:hidden">
        {tabs.map((t) => {
          const active = tab === t.key
          return (
            <button
              key={t.key}
              type="button"
              role="tab"
              id={`${id}-tab-${t.key}`}
              aria-selected={active}
              aria-controls={`${id}-panel-${t.key}`}
              onClick={() => setTab(t.key)}
              className={cn(
                'flex h-11 min-w-0 items-center justify-center gap-2 rounded-full px-3 text-sm font-semibold transition-colors focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-ring',
                active ? 'bg-primary text-primary-foreground' : 'text-muted hover:bg-hover-tint hover:text-foreground'
              )}
            >
              {t.label}
              {t.key === 'line' && (
                <span
                  className={cn(
                    'grid h-6 min-w-6 place-items-center rounded-full px-1.5 text-xs font-bold tabular-nums',
                    active ? 'bg-primary-foreground/20' : 'bg-gold text-[#18181b]'
                  )}
                  title={t.hint ?? undefined}
                >
                  {waitingCount + servingCount}
                </span>
              )}
            </button>
          )
        })}
      </div>

      <div className="grid items-start gap-6 lg:grid-cols-[minmax(0,5fr)_minmax(0,6fr)]">
        <div
          role="tabpanel"
          id={`${id}-panel-scan`}
          aria-labelledby={`${id}-tab-scan`}
          className={cn(tab === 'scan' ? 'block' : 'hidden', 'lg:block')}
        >
          {scanner}
        </div>
        <div
          role="tabpanel"
          id={`${id}-panel-line`}
          aria-labelledby={`${id}-tab-line`}
          className={cn(tab === 'line' ? 'block' : 'hidden', 'lg:block')}
        >
          {line}
        </div>
      </div>
    </div>
  )
}
