'use client'

import { useActionState, useState } from 'react'
import { Button } from '@/components/ui/Button'
import { FIELD, FIELD_LABEL } from '@/components/ui/Input'
import { PASSWORD_MAX_LENGTH, PASSWORD_MIN_LENGTH, passwordRules, passwordStrength } from '@/lib/auth/password-policy'
import { setPassword, type SetPasswordState } from './actions'

const INITIAL_STATE: SetPasswordState = { error: null }

// One color per strength level (1 Weak, 2 Fair, 3 Good, 4 Strong); the word is always written next to the bar, so the
// color is never the only signal.
const STRENGTH_COLOR = ['bg-border', 'bg-danger', 'bg-warning', 'bg-success', 'bg-success'] as const

export function SetPasswordForm() {
  const [state, formAction, isPending] = useActionState(setPassword, INITIAL_STATE)
  const [visible, setVisible] = useState(false)
  const [typed, setTyped] = useState('')
  const rules = passwordRules(typed)
  const strength = passwordStrength(typed)
  const type = visible ? 'text' : 'password'

  return (
    <form action={formAction} className="flex flex-col gap-4">
      <div className="flex flex-col gap-1.5">
        <label htmlFor="password" className={FIELD_LABEL}>
          New password
        </label>
        <input
          id="password"
          name="password"
          type={type}
          autoComplete="new-password"
          required
          minLength={PASSWORD_MIN_LENGTH}
          maxLength={PASSWORD_MAX_LENGTH}
          value={typed}
          onChange={(e) => setTyped(e.target.value)}
          aria-describedby="password-hint"
          aria-invalid={state.error ? true : undefined}
          className={FIELD}
        />
        <div>
          <div
            role="progressbar"
            aria-label="Password strength"
            aria-valuemin={0}
            aria-valuemax={4}
            aria-valuenow={strength.level}
            aria-valuetext={strength.label || 'Nothing typed yet'}
            className="grid grid-cols-4 gap-1.5"
          >
            {[1, 2, 3, 4].map((i) => (
              <span key={i} className={`h-1.5 rounded-full transition-colors ${i <= strength.level ? STRENGTH_COLOR[strength.level] : 'bg-border'}`} />
            ))}
          </div>
          <p aria-live="polite" className="mt-1.5 text-xs text-muted">
            {strength.label ? (
              <>
                Strength: <span className="font-semibold text-foreground">{strength.label}</span>
                {strength.note ? ` · ${strength.note}` : ''}
              </>
            ) : (
              'Strength: type a password to see it'
            )}
          </p>
        </div>
        <div id="password-hint" className="text-xs text-muted">
          <p>Your password needs:</p>
          <ul className="mt-1 flex flex-col gap-0.5">
            {rules.map((r) => (
              <li key={r.id} className={r.ok ? 'font-medium text-foreground' : undefined}>
                <span aria-hidden="true">{r.ok ? '✓' : '○'}</span> {r.label}
                <span className="sr-only">{r.ok ? ' (done)' : ' (not yet)'}</span>
              </li>
            ))}
          </ul>
          <p className="mt-1">It cannot be your student ID.</p>
        </div>
      </div>

      <div className="flex flex-col gap-1.5">
        <label htmlFor="confirm" className={FIELD_LABEL}>
          Confirm password
        </label>
        <input
          id="confirm"
          name="confirm"
          type={type}
          autoComplete="new-password"
          required
          minLength={PASSWORD_MIN_LENGTH}
          maxLength={PASSWORD_MAX_LENGTH}
          aria-invalid={state.error ? true : undefined}
          className={FIELD}
        />
      </div>

      <label className="flex items-center gap-2 text-sm text-muted">
        <input type="checkbox" checked={visible} onChange={(e) => setVisible(e.target.checked)} className="size-4 accent-primary" />
        Show passwords
      </label>

      {state.error && (
        <p role="alert" className="rounded-md bg-danger-soft px-3 py-2 text-sm text-danger">
          {state.error}
        </p>
      )}

      <Button type="submit" disabled={isPending} aria-busy={isPending} className="w-full">
        {isPending ? 'Saving...' : 'Save password and continue'}
      </Button>
    </form>
  )
}
