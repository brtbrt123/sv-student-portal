'use client'

import { useActionState, useState } from 'react'
import { Button, EmptyRow, Section, Select, StatusBadge, SummaryStrip, TableBody, TableCell, TableHead, TableHeader, TableRow, Textarea } from '@/components/ui'
import { Icon } from '@/components/layout/Icon'
import { cn } from '@/lib/utils'
import { formatShortDate } from '@/components/student/format'
import { decideEnrollment, type DecideEnrollmentState } from '@/lib/data/enrollments-review-actions'
import { DropSectionButton } from './DropSectionButton'
import type { EnrollmentReviewItem, EnrollmentStatus } from '@/lib/data/enrollments-review'
import RowRadio from './RowRadio'
import { QueueSheet, QueueTable, StatusLine, StudentCell } from './QueueParts'

type Filter = EnrollmentStatus | 'All'

const FILTERS: readonly Filter[] = ['Pending', 'Approved', 'Rejected', 'All']
const INITIAL: DecideEnrollmentState = { status: 'idle', message: '' }

// Pending first, then the rest; inside each group the list keeps its order (oldest submission first).
const RANK: Record<EnrollmentStatus, number> = { Pending: 0, Approved: 1, Rejected: 2 }

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

function SectionsList({ enrollment }: { enrollment: EnrollmentReviewItem }) {
  const showSeats = enrollment.status === 'Pending'
  return (
    <div className="overflow-hidden rounded-md border border-border">
      <div className="w-full overflow-x-auto">
        <QueueTable minWidth="min-w-[560px]">
          <TableHeader>
            <tr>
              <TableHead>Subject</TableHead>
              <TableHead>Section</TableHead>
              <TableHead>Units</TableHead>
              {showSeats && <TableHead>Seats taken</TableHead>}
              {showSeats && <TableHead>Drop</TableHead>}
            </tr>
          </TableHeader>
          <TableBody>
            {enrollment.sections.length === 0 && (
              <EmptyRow colSpan={showSeats ? 5 : 3}>No sections were added to this enrollment.</EmptyRow>
            )}
            {enrollment.sections.map((s) => {
              const full = s.taken >= s.capacity
              return (
                <TableRow key={s.sectionId}>
                  <TableCell>
                    <span className="block font-semibold">{s.subjectCode}</span>
                    <span className="block text-xs text-muted">{s.subjectTitle}</span>
                  </TableCell>
                  <TableCell className="text-muted">
                    {s.sectionCode}
                    {s.schedule && <span className="block text-xs">{s.schedule}</span>}
                  </TableCell>
                  <TableCell className="text-muted">{s.units}</TableCell>
                  {showSeats && (
                    <TableCell className={full ? 'font-medium text-danger' : 'text-muted'}>
                      {s.taken} / {s.capacity}
                      {full && ' (full)'}
                    </TableCell>
                  )}
                  {showSeats && (
                    <TableCell>
                      <DropSectionButton enrollmentId={enrollment.id} itemId={s.itemId} label={`${s.subjectCode} for ${enrollment.studentName}`} />
                    </TableCell>
                  )}
                </TableRow>
              )
            })}
          </TableBody>
        </QueueTable>
      </div>
    </div>
  )
}

// The panel for one selected enrollment: its sections and, only while Pending, the decision buttons.
// Approved and Rejected are final, so they show who decided and when, read-only.
function ReviewPanel({ enrollment }: { enrollment: EnrollmentReviewItem }) {
  const [state, formAction, pending] = useActionState(decideEnrollment, INITIAL)
  const isPending = enrollment.status === 'Pending'

  return (
    // The decision form wraps ONLY the remarks and the buttons: the sections list has its own Drop forms, and forms
    // cannot be nested (a Drop inside this form never ran).
    <div className="flex flex-col gap-4 rounded-lg border border-edge bg-card p-4 lg:p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-sm font-semibold">
            {enrollment.studentName}
            {enrollment.studentNo && ` (${enrollment.studentNo})`}
          </p>
          <p className="text-sm text-muted">
            {enrollment.termLabel} · Year {enrollment.yearLevel} · submitted {formatDateTime(enrollment.submittedAt)}
          </p>
          <p className="text-sm text-muted">
            {enrollment.sections.length} {enrollment.sections.length === 1 ? 'section' : 'sections'} · {enrollment.totalUnits} units
          </p>
        </div>
        <StatusBadge status={enrollment.status} />
      </div>

      <SectionsList enrollment={enrollment} />

      {!isPending && (
        <div className="flex flex-col gap-1 text-sm text-muted">
          <p>
            {enrollment.status} on {formatDateTime(enrollment.reviewedAt)}
            {enrollment.reviewedByName && ` by ${enrollment.reviewedByName}`}. This decision is final.
          </p>
          {enrollment.remarks && <p>Remarks: {enrollment.remarks}</p>}
        </div>
      )}

      {isPending && (
        <form action={formAction} className="flex flex-col gap-4">
          <input type="hidden" name="enrollmentId" value={enrollment.id} />
          <input type="hidden" name="from" value={enrollment.status} />
          <Textarea
            id={`remarks-${enrollment.id}`}
            name="remarks"
            label="Remarks (optional, required to reject)"
            rows={2}
            maxLength={300}
            placeholder="e.g. Please see the Registrar about your missing requirement"
          />
          <div className="flex flex-wrap gap-2">
            <Button
              type="submit"
              name="status"
              value="Approved"
              disabled={pending}
              aria-disabled={pending}
              className="max-sm:w-full"
            >
              <Icon name="check" className="size-4" />
              Approve enrollment
            </Button>
            <Button
              type="submit"
              name="status"
              value="Rejected"
              variant="danger"
              disabled={pending}
              aria-disabled={pending}
              className="max-sm:w-full"
            >
              Reject
            </Button>
          </div>
          <p
            role="status"
            aria-live="polite"
            className={state.status === 'error' ? 'text-sm font-medium text-danger' : 'text-sm text-muted'}
          >
            {state.message}
          </p>
        </form>
      )}
    </div>
  )
}

export default function EnrollmentsReview({ enrollments }: { enrollments: EnrollmentReviewItem[] }) {
  const [filter, setFilter] = useState<Filter>('Pending')
  const [selectedId, setSelectedId] = useState<number | null>(null)

  const count = (s: EnrollmentStatus) => enrollments.filter((e) => e.status === s).length
  const shown = (filter === 'All' ? [...enrollments].sort((a, b) => RANK[a.status] - RANK[b.status]) : enrollments.filter((e) => e.status === filter))
  const current = enrollments.find((e) => e.id === selectedId)
  const pendingCount = count('Pending')

  return (
    <div className="flex flex-col gap-6">
      <SummaryStrip
        items={[
          { label: 'Needs review', value: pendingCount, hint: 'pending', hue: pendingCount ? 'amber' : undefined },
          { label: 'Approved', value: count('Approved'), hint: 'enrolled' },
          { label: 'Rejected', value: count('Rejected'), hint: 'sent back' },
        ]}
      />

      <Section title="Submitted enrollments">
        <QueueSheet
          toolbar={
            <>
              <div className="w-44 max-sm:w-full">
                <Select
                  id="enrollment-filter"
                  label="Show"
                  value={filter}
                  onChange={(e) => setFilter(e.target.value as Filter)}
                >
                  {FILTERS.map((f) => (
                    <option key={f} value={f}>
                      {f === 'All' ? 'All statuses' : f}
                    </option>
                  ))}
                </Select>
              </div>
              <StatusLine>
                {current ? `Selected: ${current.studentName}, ${current.termLabel}.` : 'Select an enrollment to review its sections.'}
              </StatusLine>
            </>
          }
          footer={
            <p className="text-sm text-muted">
              {shown.length} {shown.length === 1 ? 'enrollment' : 'enrollments'}
              {filter !== 'All' && ` · ${filter}`}
            </p>
          }
        >
          <QueueTable minWidth="min-w-[820px]">
            <TableHeader>
              <tr>
                <TableHead className="w-12"><span className="sr-only">Select</span></TableHead>
                <TableHead>Student</TableHead>
                <TableHead>Term</TableHead>
                <TableHead>Year</TableHead>
                <TableHead>Sections</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Submitted</TableHead>
              </tr>
            </TableHeader>
            <TableBody>
              {shown.length === 0 && (
                <EmptyRow colSpan={7}>
                  {enrollments.length === 0 ? 'No enrollments have been submitted yet.' : `No ${filter.toLowerCase()} enrollments.`}
                </EmptyRow>
              )}
              {shown.map((e) => (
                <TableRow key={e.id} className={cn(selectedId === e.id && 'bg-accent')}>
                  <TableCell className="w-12 px-1.5">
                    <RowRadio
                      name="enrollment"
                      checked={selectedId === e.id}
                      onChange={() => setSelectedId(e.id)}
                      label={`Select ${e.studentName}, ${e.termLabel}`}
                    />
                  </TableCell>
                  <TableCell><StudentCell name={e.studentName} sub={e.studentNo} /></TableCell>
                  <TableCell className="whitespace-nowrap text-muted">{e.termLabel}</TableCell>
                  <TableCell className="text-muted">{e.yearLevel}</TableCell>
                  <TableCell className="text-muted">
                    {e.sections.length === 0 ? (
                      'None'
                    ) : (
                      <>
                        <span className="block">
                          {e.sections.length} {e.sections.length === 1 ? 'section' : 'sections'} · {e.totalUnits} units
                        </span>
                        <span className="block text-xs">{e.sections.map((s) => s.subjectCode).join(', ')}</span>
                      </>
                    )}
                  </TableCell>
                  <TableCell><StatusBadge status={e.status} /></TableCell>
                  <TableCell className="whitespace-nowrap text-muted">{formatShortDate(e.submittedAt)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </QueueTable>
        </QueueSheet>
      </Section>

      {current && (
        <Section title="Review enrollment">
          {/* key: a new selection starts a fresh form and message. */}
          <ReviewPanel key={current.id} enrollment={current} />
        </Section>
      )}
    </div>
  )
}
