'use client'

import { Button, Input, Select, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui'
import TableCard from '@/components/admin/TableCard'
import { createSubject, updateSubject } from '@/lib/data/catalog-actions'
import type { CatalogDepartment, CatalogSubject } from '@/lib/data/catalog'
import { MAX_UNITS, MIN_UNITS } from '@/lib/data/catalog-validate'
import { CATALOG_MUTED, FixedValue, FormPanel, Notice, useCatalogAction, usePanel } from './CatalogParts'

function SubjectForm({
  subject,
  departments,
  onClose,
  onDone,
}: {
  subject: CatalogSubject | null
  departments: CatalogDepartment[]
  onClose: () => void
  onDone: (m: string) => void
}) {
  const [state, formAction, pending] = useCatalogAction(subject ? updateSubject : createSubject, onDone)
  return (
    <FormPanel
      title={subject ? `Edit ${subject.code}` : 'Add a subject'}
      formAction={formAction}
      pending={pending}
      state={state}
      onCancel={onClose}
      submitLabel={subject ? 'Save subject' : 'Add subject'}
    >
      {subject && <input type="hidden" name="subjectId" value={subject.id} />}
      <Input id="subject-code" name="code" label="Subject code" maxLength={20} required defaultValue={subject?.code ?? ''} />
      <Input id="subject-title" name="title" label="Title" maxLength={120} required defaultValue={subject?.title ?? ''} />
      <Input
        id="subject-units"
        name="units"
        type="number"
        inputMode="numeric"
        min={MIN_UNITS}
        max={MAX_UNITS}
        step={1}
        label={`Units (${MIN_UNITS} to ${MAX_UNITS})`}
        required
        defaultValue={subject?.units ?? 3}
      />
      {subject ? (
        <FixedValue label="Department" value={subject.departmentName} />
      ) : (
        <Select id="subject-dept" name="departmentId" label="Department" required defaultValue="">
          <option value="" disabled>
            Choose a department
          </option>
          {departments.map((d) => (
            <option key={d.id} value={d.id}>
              {d.name}
            </option>
          ))}
        </Select>
      )}
    </FormPanel>
  )
}

export function CatalogSubjects({ subjects, departments }: { subjects: CatalogSubject[]; departments: CatalogDepartment[] }) {
  const panel = usePanel<CatalogSubject>()
  const editing = typeof panel.mode === 'object' ? panel.mode.edit : null

  return (
    <div className="flex flex-col gap-3">
      <TableCard
        title="Subjects"
        action={
          <Button variant="outline" onClick={panel.openAdd}>
            Add subject
          </Button>
        }
        minWidth="min-w-[640px]"
      >
        <TableHeader>
          <TableRow className="hover:bg-transparent">
            {['Code', 'Title', 'Units', 'Department', 'Actions'].map((c) => (
              <TableHead key={c} scope="col">
                {c}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {subjects.length === 0 && (
            <TableRow>
              <TableCell colSpan={5} className="py-8 text-center text-muted">
                No subjects yet.
              </TableCell>
            </TableRow>
          )}
          {subjects.map((s) => (
            <TableRow key={s.id}>
              <TableCell>{s.code}</TableCell>
              <TableCell className={CATALOG_MUTED}>{s.title}</TableCell>
              <TableCell className={CATALOG_MUTED}>{s.units}</TableCell>
              <TableCell className={CATALOG_MUTED}>{s.departmentName}</TableCell>
              <TableCell>
                <Button variant="ghost" onClick={() => panel.openEdit(s)} aria-label={`Edit subject ${s.code}`}>
                  Edit
                </Button>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </TableCard>
      {panel.mode !== 'closed' && (
        <SubjectForm
          key={editing ? `e${editing.id}` : 'add'}
          subject={editing}
          departments={departments}
          onClose={panel.close}
          onDone={panel.done}
        />
      )}
      <Notice text={panel.notice.text} tone={panel.notice.ok ? 'success' : 'error'} />
    </div>
  )
}
