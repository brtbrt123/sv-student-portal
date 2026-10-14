'use client'

import { useActionState } from 'react'
import { Input } from '@/components/ui/Input'
import { Select } from '@/components/ui/Select'
import { submitApplication, type ApplyState } from '@/lib/data/apply-actions'
import type { ProgramOption } from './programs'

const INITIAL_STATE: ApplyState = { status: 'idle', message: '' }

// 16 px text on a phone keeps iOS from zooming the page when a field is tapped; a taller field is easier to hit.
const FIELD_SIZE = 'h-12 rounded-xl text-base max-lg:h-12'

function Field({
  id,
  label,
  required,
  hint,
  error,
  children,
}: {
  id: string
  label: string
  required?: boolean
  hint?: string
  error?: string
  children: React.ReactNode
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <label htmlFor={id} className="text-sm font-semibold text-foreground">
        {label}
        {required ? (
          <span aria-hidden="true" className="ml-0.5 text-danger">
            *
          </span>
        ) : (
          <span className="ml-1.5 text-xs font-normal text-muted">(optional)</span>
        )}
      </label>
      {children}
      {error ? (
        <p id={`${id}-error`} role="alert" className="text-[13px] leading-5 font-medium text-danger">
          {error}
        </p>
      ) : hint ? (
        <p id={`${id}-hint`} className="text-[13px] leading-5 text-muted">
          {hint}
        </p>
      ) : null}
    </div>
  )
}

function GroupTitle({ n, children }: { n: number; children: React.ReactNode }) {
  return (
    <div aria-hidden="true" className="flex items-center gap-2.5 text-base font-semibold">
      <span className="grid size-7 place-items-center rounded-full bg-gold text-sm font-extrabold text-[#18181b]">{n}</span>
      {children}
    </div>
  )
}

export function ApplyForm({ programs }: { programs: ProgramOption[] }) {
  const [state, formAction, isPending] = useActionState(submitApplication, INITIAL_STATE)
  const fe = state.fieldErrors ?? {}
  const v = state.values
  const describe = (id: string, error?: string, hint?: boolean) => (error ? `${id}-error` : hint ? `${id}-hint` : undefined)

  return (
    <form action={formAction} noValidate className="relative flex flex-col gap-7">
      <p className="text-[13px] text-muted">
        Fields marked <span aria-hidden="true" className="font-semibold text-danger">*</span>
        <span className="sr-only">with an asterisk</span> are required.
      </p>

      <fieldset className="flex flex-col gap-4">
        <legend className="sr-only">About you</legend>
        <GroupTitle n={1}>About you</GroupTitle>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field id="firstName" label="First name" required error={fe.firstName}>
            <Input
              id="firstName"
              name="firstName"
              autoComplete="given-name"
              required
              maxLength={100}
              defaultValue={v?.firstName}
              aria-invalid={fe.firstName ? true : undefined}
              aria-describedby={describe('firstName', fe.firstName)}
              className={FIELD_SIZE}
            />
          </Field>
          <Field id="lastName" label="Last name" required error={fe.lastName}>
            <Input
              id="lastName"
              name="lastName"
              autoComplete="family-name"
              required
              maxLength={100}
              defaultValue={v?.lastName}
              aria-invalid={fe.lastName ? true : undefined}
              aria-describedby={describe('lastName', fe.lastName)}
              className={FIELD_SIZE}
            />
          </Field>
        </div>
        <Field id="email" label="Email address" required error={fe.email} hint="We send your student ID and a link to set your password here.">
          <Input
            id="email"
            name="email"
            type="email"
            autoComplete="email"
            inputMode="email"
            spellCheck={false}
            required
            maxLength={254}
            defaultValue={v?.email}
            aria-invalid={fe.email ? true : undefined}
            aria-describedby={describe('email', fe.email, true)}
            className={FIELD_SIZE}
          />
        </Field>
        <Field id="mobile" label="Mobile number" error={fe.mobile} hint="Only used if the Registrar needs to reach you.">
          <Input
            id="mobile"
            name="mobile"
            type="tel"
            autoComplete="tel"
            inputMode="tel"
            maxLength={20}
            defaultValue={v?.mobile}
            aria-invalid={fe.mobile ? true : undefined}
            aria-describedby={describe('mobile', fe.mobile, true)}
            className={FIELD_SIZE}
          />
        </Field>
      </fieldset>

      <fieldset className="flex flex-col gap-4">
        <legend className="sr-only">Your program</legend>
        <GroupTitle n={2}>Your program</GroupTitle>
        <Field id="programId" label="Program" required error={fe.programId} hint="Choose the program you want to enroll in.">
          <Select
            id="programId"
            name="programId"
            required
            defaultValue={v?.programId ?? ''}
            aria-invalid={fe.programId ? true : undefined}
            aria-describedby={describe('programId', fe.programId, true)}
            className={FIELD_SIZE}
          >
            <option value="" disabled>
              {programs.length === 0 ? 'Programs are unavailable right now' : 'Choose a program'}
            </option>
            {programs.map((p) => (
              <option key={p.program_id} value={p.program_id}>
                {p.code} - {p.name}
              </option>
            ))}
          </Select>
        </Field>
      </fieldset>

      {/* Honeypot: hidden from people and assistive tech. Bots fill it; the server then ignores the application. */}
      <div aria-hidden="true" className="absolute -left-[9999px] h-0 w-0 overflow-hidden">
        <label htmlFor="website">Website</label>
        <input id="website" name="website" type="text" tabIndex={-1} autoComplete="off" />
      </div>

      {state.status === 'error' && state.message && (
        <p role="alert" className="rounded-xl bg-danger-soft px-4 py-3 text-sm font-medium text-danger">
          {state.message}
        </p>
      )}

      <div className="flex flex-col gap-3">
        <button
          type="submit"
          disabled={isPending || programs.length === 0}
          aria-busy={isPending}
          className="inline-flex h-12 w-full items-center justify-center rounded-full bg-gold px-6 text-base font-bold text-[#18181b] shadow-elev-xs transition hover:brightness-95 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring disabled:pointer-events-none disabled:opacity-60"
        >
          {isPending ? 'Sending your application...' : 'Submit application'}
        </button>
        <p className="text-center text-[13px] leading-5 text-muted">
          By submitting, you agree that we use these details for your enrollment only.{' '}
          <a href="#your-data" className="font-medium text-foreground underline underline-offset-4">
            How we use your data
          </a>
        </p>
      </div>
    </form>
  )
}
