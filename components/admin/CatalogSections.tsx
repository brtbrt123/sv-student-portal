'use client'

import { useState } from 'react'
import { Button, Input, Select, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui'
import TableCard from '@/components/admin/TableCard'
import { createSection, updateSection } from '@/lib/data/catalog-actions'
import type { CatalogSection, CatalogSubject, CatalogTerm } from '@/lib/data/catalog'
import { MAX_CAPACITY, MIN_CAPACITY } from '@/lib/data/catalog-validate'
import { CATALOG_MUTED, FixedValue, FormPanel, Notice, useCatalogAction, usePanel } from './CatalogParts'

function SectionForm({
  section,
  subjects,
  terms,
  currentTermId,
  onClose,
  onDone,
}: {
  section: CatalogSection | null
  subjects: CatalogSubject[]
  terms: CatalogTerm[]
  currentTermId: number | null
  onClose: () => void
  onDone: (m: string) => void
}) {
  const [state, formAction, pending] = useCatalogAction(section ? updateSection : createSection, onDone)
  return (
    <FormPanel
      title={section ? `Edit section ${section.sectionCode}` : 'Add a section'}
      formAction={formAction}
      pending={pending}
      state={state}
      onCancel={onClose}
      submitLabel={section ? 'Save section' : 'Add section'}
    >
      {section ? (
        <>
          <input type="hidden" name="sectionId" value={section.id} />
          <FixedValue label="Subject" value={`${section.subjectCode} ${section.subjectTitle}`} />
          <FixedValue label="Term" value={section.termLabel} />
        </>
      ) : (
        <>
          <Select id="section-subject" name="subjectId" label="Subject" required defaultValue="">
            <option value="" disabled>
              Choose a subject
            </option>
            {subjects.map((s) => (
              <option key={s.id} value={s.id}>
                {s.code} {s.title}
              </option>
            ))}
          </Select>
          <Select id="section-term" name="termId" label="Term" required defaultValue={currentTermId ? String(currentTermId) : ''}>
            {!currentTermId && (
              <option value="" disabled>
                Choose a term
              </option>
            )}
            {terms.map((t) => (
              <option key={t.id} value={t.id}>
                {t.label}
                {t.isCurrent ? ' (current)' : ''}
              </option>
            ))}
          </Select>
        </>
      )}
      <Input id="section-code" name="sectionCode" label="Section code" maxLength={20} required defaultValue={section?.sectionCode ?? ''} />
      <Input
        id="section-schedule"
        name="schedule"
        label="Schedule"
        placeholder="MWF 8:00-9:00"
        maxLength={60}
        required
        defaultValue={section?.schedule ?? ''}
      />
      <Input
        id="section-capacity"
        name="capacity"
        type="number"
        inputMode="numeric"
        min={MIN_CAPACITY}
        max={MAX_CAPACITY}
        step={1}
        label="Capacity (seats)"
        required
        defaultValue={section?.capacity ?? 40}
      />
    </FormPanel>
  )
}

export function CatalogSections({
  sections,
  subjects,
  terms,
  currentTermId,
}: {
  sections: CatalogSection[]
  subjects: CatalogSubject[]
  terms: CatalogTerm[]
  currentTermId: number | null
}) {
  const panel = usePanel<CatalogSection>()
  const [termFilter, setTermFilter] = useState<string>(currentTermId ? String(currentTermId) : 'all')
  const editing = typeof panel.mode === 'object' ? panel.mode.edit : null
  const shown = termFilter === 'all' ? sections : sections.filter((s) => String(s.termId) === termFilter)

  return (
    <div className="flex flex-col gap-3">
      <TableCard
        title="Sections"
        description="A section must belong to the current term before students can enrol in it."
        action={
          <Button variant="outline" onClick={panel.openAdd} disabled={terms.length === 0 || subjects.length === 0}>
            Add section
          </Button>
        }
        minWidth="min-w-[760px]"
      >
        <TableHeader>
          <TableRow className="hover:bg-transparent">
            {['Section', 'Subject', 'Term', 'Schedule', 'Capacity', 'Actions'].map((c) => (
              <TableHead key={c} scope="col">
                {c}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {shown.length === 0 && (
            <TableRow>
              <TableCell colSpan={6} className="py-8 text-center text-muted">
                No sections for this term yet.
              </TableCell>
            </TableRow>
          )}
          {shown.map((s) => (
            <TableRow key={s.id}>
              <TableCell>{s.sectionCode}</TableCell>
              <TableCell className={CATALOG_MUTED}>
                {s.subjectCode} {s.subjectTitle}
              </TableCell>
              <TableCell className={CATALOG_MUTED}>{s.termLabel}</TableCell>
              <TableCell className={`whitespace-nowrap ${CATALOG_MUTED}`}>{s.schedule || '-'}</TableCell>
              <TableCell className={CATALOG_MUTED}>{s.capacity}</TableCell>
              <TableCell>
                <Button variant="ghost" onClick={() => panel.openEdit(s)} aria-label={`Edit section ${s.sectionCode} of ${s.subjectCode}`}>
                  Edit
                </Button>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </TableCard>
      <div className="max-w-xs">
        <Select id="section-filter" label="Show sections of" value={termFilter} onChange={(e) => setTermFilter(e.target.value)}>
          <option value="all">All terms</option>
          {terms.map((t) => (
            <option key={t.id} value={t.id}>
              {t.label}
              {t.isCurrent ? ' (current)' : ''}
            </option>
          ))}
        </Select>
      </div>
      {panel.mode !== 'closed' && (
        <SectionForm
          key={editing ? `e${editing.id}` : 'add'}
          section={editing}
          subjects={subjects}
          terms={terms}
          currentTermId={currentTermId}
          onClose={panel.close}
          onDone={panel.done}
        />
      )}
      <Notice text={panel.notice.text} tone={panel.notice.ok ? 'success' : 'error'} />
    </div>
  )
}
