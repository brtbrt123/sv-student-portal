import { EmptyState } from '@/components/ui'
import type { DeptActionState } from '@/lib/data/department-actions'

export const DEPT_IDLE: DeptActionState = { status: 'idle', message: '', stamp: 0 }

// Result of the last action, announced politely. The region is always mounted so screen readers pick
// up the text when it appears. Errors use the danger colour and say so in words too.
export function ActionMessage({ state, className }: { state: DeptActionState; className?: string }) {
  const isError = state.status === 'error'
  return (
    <p
      role="status"
      aria-live="polite"
      className={
        (isError ? 'text-sm font-medium text-danger' : 'text-sm text-foreground') +
        (state.message ? ' rounded-md border border-edge bg-card px-4 py-3' : '') +
        (className ? ` ${className}` : '')
      }
    >
      {state.message || null}
    </p>
  )
}

// Shown instead of a screen's content when the live data could not be loaded.
export function DeptUnavailable({ kind }: { kind: 'no-department' | 'error' }) {
  if (kind === 'no-department') {
    return (
      <EmptyState title="Your account is not linked to a department">
        An administrator needs to assign you to a department before you can review clearance items or place holds.
      </EmptyState>
    )
  }
  return (
    <div role="alert">
      <EmptyState title="We could not load this page">
        Something went wrong on our side. Reload the page, and if it keeps happening, come back in a few minutes.
      </EmptyState>
    </div>
  )
}
