'use client'

import { useActionState, useState } from 'react'
import { Button } from '@/components/ui'
import type { CatalogActionState } from '@/lib/data/catalog-actions'

export const CATALOG_MUTED = 'font-normal text-muted'

const INITIAL: CatalogActionState = { status: 'idle', message: '' }

type Action = (prev: CatalogActionState, formData: FormData) => Promise<CatalogActionState>

// Wraps a Server Action for useActionState and calls onDone when it succeeded (to close the form panel).
export function useCatalogAction(action: Action, onDone?: (message: string) => void) {
  return useActionState(async (prev: CatalogActionState, formData: FormData) => {
    const result = await action(prev, formData)
    if (result.status === 'success') onDone?.(result.message)
    return result
  }, INITIAL)
}

// The result of the last save, shown above the tables. Polite for success, an alert for errors.
export function Notice({ text, tone }: { text: string; tone: 'success' | 'error' }) {
  if (!text) return null
  return (
    <p
      role={tone === 'error' ? 'alert' : 'status'}
      className={`rounded-lg border px-4 py-3 text-sm ${
        tone === 'error' ? 'border-danger/30 bg-danger-soft text-danger' : 'border-edge bg-card text-foreground'
      }`}
    >
      {text}
    </p>
  )
}

// One add or edit form. It is rendered OUTSIDE the table (forms are never nested). `children` are the fields.
export function FormPanel({
  title,
  formAction,
  pending,
  state,
  onCancel,
  submitLabel,
  children,
}: {
  title: string
  formAction: (formData: FormData) => void
  pending: boolean
  state: CatalogActionState
  onCancel: () => void
  submitLabel: string
  children: React.ReactNode
}) {
  return (
    <form action={formAction} className="flex flex-col gap-4 rounded-lg border border-edge bg-card p-4">
      <h3 className="text-sm font-semibold">{title}</h3>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">{children}</div>
      {state.status === 'error' && state.message && (
        <p role="alert" className="text-sm font-medium text-danger">
          {state.message}
        </p>
      )}
      <div className="flex flex-wrap gap-2">
        <Button type="submit" disabled={pending} aria-disabled={pending}>
          {pending ? 'Saving...' : submitLabel}
        </Button>
        <Button type="button" variant="outline" onClick={onCancel}>
          Cancel
        </Button>
      </div>
    </form>
  )
}

// A read-only value shown in place of a field that cannot change after creation.
export function FixedValue({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col gap-1.5">
      <span className="text-[13px] leading-5 font-medium text-foreground">{label}</span>
      <p className="flex min-h-10 items-center rounded-md border border-edge px-4 text-sm text-muted max-lg:min-h-11">
        {value} <span className="ml-2 text-[13px]">(cannot be changed)</span>
      </p>
    </div>
  )
}

// Shared open/close state for a table card with one form panel (adding or editing one row), plus the
// result line shown under the table.
export function usePanel<T>() {
  const [mode, setMode] = useState<'closed' | 'add' | { edit: T }>('closed')
  const [notice, setNotice] = useState<{ text: string; ok: boolean }>({ text: '', ok: true })
  return {
    mode,
    notice,
    openAdd: () => {
      setNotice({ text: '', ok: true })
      setMode('add')
    },
    openEdit: (row: T) => {
      setNotice({ text: '', ok: true })
      setMode({ edit: row })
    },
    close: () => setMode('closed'),
    done: (message: string) => {
      setNotice({ text: message, ok: true })
      setMode('closed')
    },
    report: (text: string, ok: boolean) => setNotice({ text, ok }),
  }
}
