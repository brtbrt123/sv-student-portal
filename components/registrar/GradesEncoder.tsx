'use client'

import { useActionState, useId, useState } from 'react'
import { Badge, Button, EmptyRow, Input, Section, Select, SummaryStrip, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui'
import { cn } from '@/lib/utils'
import { encodeGrade, type EncodeGradeState } from '@/lib/data/grades-actions'
import type { EncodableItem, GradeScaleOption } from '@/lib/data/grades'
import { QueueSheet, QueueTable, StudentCell } from './QueueParts'

const INITIAL: EncodeGradeState = { status: 'idle', message: '' }

// One row = one small form: pick a grade from the scale and save. Inserts or corrects on the server.
function GradeRow({ item, scale }: { item: EncodableItem; scale: GradeScaleOption[] }) {
  const [state, formAction, pending] = useActionState(encodeGrade, INITIAL)
  const uid = useId()
  const selectId = `${uid}-grade`
  const msgId = `${uid}-msg`
  const formId = `${uid}-form`

  return (
    <TableRow>
      <TableCell>
        <StudentCell name={item.studentName} sub={item.studentNo || undefined} />
      </TableCell>
      <TableCell>
        <span className="block font-semibold">{item.subjectCode}</span>
        <span className="block text-xs text-muted">
          {item.subjectTitle} · Section {item.sectionCode}
        </span>
      </TableCell>
      <TableCell>
        <form id={formId} action={formAction} className="flex items-center gap-2">
          <input type="hidden" name="enrollmentItemId" value={item.enrollmentItemId} />
          <label htmlFor={selectId} className="sr-only">
            Grade for {item.studentName}, {item.subjectCode}
          </label>
          <Select
            id={selectId}
            name="gradeCode"
            defaultValue={item.gradeCode ?? ''}
            required
            aria-describedby={msgId}
            className="w-44 min-h-11 lg:min-h-0"
          >
            <option value="" disabled>
              Select grade
            </option>
            {scale.map((s) => (
              <option key={s.code} value={s.code}>
                {s.code} · {s.description}
              </option>
            ))}
          </Select>
          <Button type="submit" variant="outline" disabled={pending} className="min-h-11 lg:min-h-0">
            {pending ? 'Saving...' : item.gradeCode ? 'Update' : 'Save'}
          </Button>
        </form>
      </TableCell>
      <TableCell>
        {item.gradeCode ? <Badge tone="success">Encoded</Badge> : <Badge tone="neutral">Not encoded</Badge>}
        <p
          id={msgId}
          role="status"
          aria-live="polite"
          className={cn('mt-1 max-w-[36ch] text-xs', state.status === 'error' ? 'font-medium text-danger' : 'text-muted')}
        >
          {state.message}
        </p>
      </TableCell>
    </TableRow>
  )
}

export default function GradesEncoder({ items, scale }: { items: EncodableItem[]; scale: GradeScaleOption[] }) {
  const [sectionId, setSectionId] = useState('all')
  const [query, setQuery] = useState('')
  const [onlyMissing, setOnlyMissing] = useState(false)

  // One entry per section, labelled with its subject.
  const sections = [...new Map(items.map((i) => [i.sectionId, i])).values()].sort(
    (a, b) => a.subjectCode.localeCompare(b.subjectCode) || a.sectionCode.localeCompare(b.sectionCode)
  )

  const q = query.trim().toLowerCase()
  const visible = items.filter(
    (i) =>
      (sectionId === 'all' || String(i.sectionId) === sectionId) &&
      (!onlyMissing || i.gradeCode === null) &&
      (!q || i.studentName.toLowerCase().includes(q) || i.studentNo.toLowerCase().includes(q.replace(/-/g, '')))
  )
  const encoded = items.filter((i) => i.gradeCode !== null).length

  return (
    <div className="flex flex-col gap-6">
      <SummaryStrip
        items={[
          { label: 'Subjects to grade', value: items.length, hint: 'approved enrollments' },
          { label: 'Encoded', value: encoded, hint: `of ${items.length}`, hue: encoded && encoded === items.length ? 'teal' : undefined },
          { label: 'Waiting', value: items.length - encoded, hint: 'no grade yet', hue: items.length - encoded ? 'amber' : undefined },
        ]}
      />

      <Section title="Class record" description="Only students with an approved enrollment can receive a grade.">
        <QueueSheet
          toolbar={
            <>
              <div className="w-full sm:w-64">
                <Select label="Section" id="grades-section" value={sectionId} onChange={(e) => setSectionId(e.target.value)}>
                  <option value="all">All sections</option>
                  {sections.map((s) => (
                    <option key={s.sectionId} value={s.sectionId}>
                      {s.subjectCode} · Section {s.sectionCode}
                    </option>
                  ))}
                </Select>
              </div>
              <div className="w-full sm:w-64">
                <Input
                  label="Search student"
                  id="grades-search"
                  type="search"
                  placeholder="Name or student number"
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                />
              </div>
              <label className="flex min-h-11 items-center gap-2 pb-1 text-sm lg:min-h-0">
                <input
                  type="checkbox"
                  checked={onlyMissing}
                  onChange={(e) => setOnlyMissing(e.target.checked)}
                  className="size-5 accent-primary"
                />
                Only without a grade
              </label>
            </>
          }
          footer={
            <p className="text-sm text-muted" aria-live="polite">
              Showing {visible.length} of {items.length} {items.length === 1 ? 'subject' : 'subjects'}
            </p>
          }
        >
          <QueueTable minWidth="min-w-[760px]">
            <TableHeader>
              <tr>
                <TableHead>Student</TableHead>
                <TableHead>Subject</TableHead>
                <TableHead>Grade</TableHead>
                <TableHead>Status</TableHead>
              </tr>
            </TableHeader>
            <TableBody>
              {visible.length === 0 && (
                <EmptyRow colSpan={4}>
                  {items.length === 0
                    ? 'No approved enrollments to grade this term yet.'
                    : 'No students match those filters.'}
                </EmptyRow>
              )}
              {visible.map((i) => (
                <GradeRow key={i.enrollmentItemId} item={i} scale={scale} />
              ))}
            </TableBody>
          </QueueTable>
        </QueueSheet>
      </Section>
    </div>
  )
}
