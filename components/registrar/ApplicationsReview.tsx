'use client'

import { useActionState, useState } from 'react'
import { Badge, Button, EmptyRow, Section, Select, SummaryStrip, TableBody, TableCell, TableHead, TableHeader, TableRow, Textarea, type BadgeTone } from '@/components/ui'
import { Icon } from '@/components/layout/Icon'
import { cn } from '@/lib/utils'
import { formatShortDate } from '@/components/student/format'
import {
  acceptApplication,
  rejectApplication,
  resendCredentials,
  retryProvisioning,
  type ApplicationActionState,
} from '@/lib/data/applications-actions'
import type { ApplicationItem, ApplicationStatus } from '@/lib/data/applications'
import RowRadio from './RowRadio'
import { QueueSheet, QueueTable, StatusLine, StudentCell } from './QueueParts'

type Filter = ApplicationStatus | 'All'

const FILTERS: readonly Filter[] = ['Pending', 'Accepted', 'Rejected', 'All']
const INITIAL: ApplicationActionState = { status: 'idle', message: '' }

// Pending first, then the rest; inside each group the list keeps its order (oldest submission first).
const RANK: Record<ApplicationStatus, number> = { Pending: 0, Accepted: 1, Rejected: 2 }
const TONE: Record<ApplicationStatus, BadgeTone> = { Pending: 'warning', Accepted: 'success', Rejected: 'danger' }

const DATE_TIME = new Intl.DateTimeFormat('en-US', {
  month: 'short',
  day: 'numeric',
  year: 'numeric',
  hour: 'numeric',
  minute: '2-digit',
  timeZone: 'Asia/Manila',
})

function formatDateTime(iso: string | null) {
  if (!iso) return '-'
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? '-' : DATE_TIME.format(d)
}

function ApplicationStatusBadge({ status }: { status: ApplicationStatus }) {
  return <Badge tone={TONE[status]}>{status}</Badge>
}

function AccountCell({ a }: { a: ApplicationItem }) {
  if (a.status !== 'Accepted') return <span className="text-muted">-</span>
  if (!a.provisioned) return <Badge tone="warning">Not set up</Badge>
  return (
    <>
      <Badge tone="success">Ready</Badge>
      {a.studentNumber && <span className="block text-xs text-muted">{a.studentNumber}</span>}
    </>
  )
}

// One action per button; each server action checks the Registrar again on its own.
async function dispatch(prev: ApplicationActionState, formData: FormData): Promise<ApplicationActionState> {
  switch (formData.get('intent')) {
    case 'accept':
      return acceptApplication(prev, formData)
    case 'reject':
      return rejectApplication(prev, formData)
    case 'retry':
      return retryProvisioning(prev, formData)
    case 'resend':
      return resendCredentials(prev, formData)
    default:
      return { status: 'error', message: 'That action is not allowed. Reload the page.' }
  }
}

function Detail({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="min-w-0">
      <dt className="text-xs text-muted">{label}</dt>
      <dd className="break-words text-sm">{children}</dd>
    </div>
  )
}

// The panel for one selected application. Pending: decide it. Accepted without an account: retry the
// account setup. Accepted with an account: show the student ID and resend the email. Rejected: read-only.
function ApplicationReviewPanel({ application: a }: { application: ApplicationItem }) {
  const [state, formAction, pending] = useActionState(dispatch, INITIAL)
  const isPending = a.status === 'Pending'

  return (
    <form action={formAction} className="flex flex-col gap-4 rounded-lg border border-edge bg-card p-4 lg:p-5">
      <input type="hidden" name="applicationId" value={a.id} />
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-sm font-semibold">{a.name}</p>
          <p className="text-sm text-muted">Submitted {formatDateTime(a.submittedAt)}</p>
        </div>
        <ApplicationStatusBadge status={a.status} />
      </div>

      <dl className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <Detail label="Email">{a.email || '-'}</Detail>
        <Detail label="Mobile">{a.mobile || '-'}</Detail>
        <Detail label="Program">
          {a.programCode} · {a.programName}
        </Detail>
        <Detail label="Applicant">
          {a.applicantType === 'Transferee' ? 'Transferee (picks their own subjects)' : 'New student (first-year subjects set automatically)'}
        </Detail>
        {a.status === 'Accepted' && (
          <Detail label="Student ID">
            {a.provisioned ? (a.studentNumber ?? 'Set up') : 'Not set up yet'}
            {a.provisionedAt && <span className="block text-xs text-muted">Account created {formatDateTime(a.provisionedAt)}</span>}
          </Detail>
        )}
      </dl>

      {!isPending && (
        <div className="flex flex-col gap-1 text-sm text-muted">
          <p>
            {a.status} on {formatDateTime(a.reviewedAt)}
            {a.reviewedByName && ` by ${a.reviewedByName}`}. This decision is final.
          </p>
          {a.remarks && <p>Remarks: {a.remarks}</p>}
        </div>
      )}

      {isPending && (
        <>
          <Textarea
            id={`remarks-${a.id}`}
            name="remarks"
            label="Remarks (optional, required to reject)"
            rows={2}
            maxLength={300}
            placeholder="e.g. Your requirements are incomplete. Please apply again next term."
          />
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" name="notify" defaultChecked className="size-4 accent-primary" />
            If rejected, email the applicant a short notice with the remarks
          </label>
          <p className="text-sm text-muted">
            Accepting creates the student account and emails the applicant their student ID and a one-time link to set a password.
          </p>
          <div className="flex flex-wrap gap-2">
            <Button type="submit" name="intent" value="accept" disabled={pending} aria-disabled={pending} className="max-sm:w-full">
              <Icon name="check" className="size-4" />
              Accept application
            </Button>
            <Button
              type="submit"
              name="intent"
              value="reject"
              variant="danger"
              disabled={pending}
              aria-disabled={pending}
              className="max-sm:w-full"
            >
              Reject
            </Button>
          </div>
        </>
      )}

      {a.status === 'Accepted' && !a.provisioned && (
        <div className="flex flex-col gap-2">
          <p className="text-sm text-muted">
            The student account was not created yet. Retry to create it and send the email.
          </p>
          <div>
            <Button type="submit" name="intent" value="retry" disabled={pending} aria-disabled={pending} className="max-sm:w-full">
              Retry account setup
            </Button>
          </div>
        </div>
      )}

      {a.status === 'Accepted' && a.provisioned && (
        <div className="flex flex-col gap-2">
          <p className="text-sm text-muted">
            Resend email creates a new one-time set-password link and sends it with the student ID.
          </p>
          <div>
            <Button
              type="submit"
              name="intent"
              value="resend"
              variant="outline"
              disabled={pending}
              aria-disabled={pending}
              className="max-sm:w-full"
            >
              Resend email
            </Button>
          </div>
        </div>
      )}

      <p
        role="status"
        aria-live="polite"
        className={cn(
          'text-sm',
          state.status === 'error' && 'font-medium text-danger',
          state.status === 'warning' && 'font-medium text-warning',
          (state.status === 'success' || state.status === 'idle') && 'text-muted'
        )}
      >
        {pending ? 'Working on it…' : state.message}
      </p>
    </form>
  )
}

export default function ApplicationsReview({ applications }: { applications: ApplicationItem[] }) {
  const [filter, setFilter] = useState<Filter>('All')
  const [selectedId, setSelectedId] = useState<string | null>(null)

  const count = (s: ApplicationStatus) => applications.filter((a) => a.status === s).length
  const shown =
    filter === 'All' ? [...applications].sort((a, b) => RANK[a.status] - RANK[b.status]) : applications.filter((a) => a.status === filter)
  const current = applications.find((a) => a.id === selectedId)
  const pendingCount = count('Pending')
  const notSetUp = applications.filter((a) => a.status === 'Accepted' && !a.provisioned).length

  return (
    <div className="flex flex-col gap-6">
      <SummaryStrip
        items={[
          { label: 'Needs review', value: pendingCount, hint: 'pending', hue: pendingCount ? 'amber' : undefined },
          { label: 'Accepted', value: count('Accepted'), hint: notSetUp ? `${notSetUp} not set up` : 'accounts ready' },
          { label: 'Rejected', value: count('Rejected'), hint: 'not admitted' },
        ]}
      />

      <Section title="Applications">
        <QueueSheet
          toolbar={
            <>
              <div className="w-44 max-sm:w-full">
                <Select id="application-filter" label="Show" value={filter} onChange={(e) => setFilter(e.target.value as Filter)}>
                  {FILTERS.map((f) => (
                    <option key={f} value={f}>
                      {f === 'All' ? 'All statuses' : f}
                    </option>
                  ))}
                </Select>
              </div>
              <StatusLine>{current ? `Selected: ${current.name}.` : 'Select an application to review it.'}</StatusLine>
            </>
          }
          footer={
            <p className="text-sm text-muted">
              {shown.length} {shown.length === 1 ? 'application' : 'applications'}
              {filter !== 'All' && ` · ${filter}`}
            </p>
          }
        >
          <QueueTable minWidth="min-w-[860px]">
            <TableHeader>
              <tr>
                <TableHead className="w-12"><span className="sr-only">Select</span></TableHead>
                <TableHead>Applicant</TableHead>
                <TableHead>Program</TableHead>
                <TableHead>Submitted</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Account</TableHead>
              </tr>
            </TableHeader>
            <TableBody>
              {shown.length === 0 && (
                <EmptyRow colSpan={6}>
                  {applications.length === 0 ? 'No applications have been submitted yet.' : `No ${filter.toLowerCase()} applications.`}
                </EmptyRow>
              )}
              {shown.map((a) => (
                <TableRow key={a.id} className={cn(selectedId === a.id && 'bg-accent')}>
                  <TableCell className="w-12 px-1.5">
                    <RowRadio name="application" checked={selectedId === a.id} onChange={() => setSelectedId(a.id)} label={`Select ${a.name}`} />
                  </TableCell>
                  <TableCell><StudentCell name={a.name} sub={a.email} /></TableCell>
                  <TableCell className="text-muted">
                    <span className="block font-medium text-foreground">{a.programCode}</span>
                    <span className="block text-xs">{a.programName}</span>
                    {a.applicantType === 'Transferee' && <span className="block text-xs">Transferee</span>}
                  </TableCell>
                  <TableCell className="whitespace-nowrap text-muted">{formatShortDate(a.submittedAt)}</TableCell>
                  <TableCell><ApplicationStatusBadge status={a.status} /></TableCell>
                  <TableCell><AccountCell a={a} /></TableCell>
                </TableRow>
              ))}
            </TableBody>
          </QueueTable>
        </QueueSheet>
      </Section>

      {current && (
        <Section title="Review application">
          {/* key: a new selection starts a fresh form and message. */}
          <ApplicationReviewPanel key={current.id} application={current} />
        </Section>
      )}
    </div>
  )
}
