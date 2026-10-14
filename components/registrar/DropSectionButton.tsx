'use client'

import { useActionState } from 'react'
import { Button } from '@/components/ui'
import { dropEnrollmentSection, type DecideEnrollmentState } from '@/lib/data/enrollments-review-actions'

const INITIAL: DecideEnrollmentState = { status: 'idle', message: '' }

// The Registrar drops one subject from a Pending enrollment when the student asks at the window. An error
// stays under the button because the row is still on the page.
export function DropSectionButton({ enrollmentId, itemId, label }: { enrollmentId: number; itemId: number; label: string }) {
  const [state, formAction, pending] = useActionState(dropEnrollmentSection, INITIAL)

  return (
    <form action={formAction}>
      <input type="hidden" name="enrollmentId" value={enrollmentId} />
      <input type="hidden" name="enrollmentItemId" value={itemId} />
      <Button type="submit" variant="outline" disabled={pending} aria-disabled={pending} aria-label={`Drop ${label}`}>
        {pending ? 'Dropping...' : 'Drop'}
      </Button>
      <p role="status" aria-live="polite" className={state.message && state.status === 'error' ? 'mt-2 max-w-[40ch] text-sm font-medium whitespace-normal text-danger' : 'sr-only'}>
        {state.message}
      </p>
    </form>
  )
}
