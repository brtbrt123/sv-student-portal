'use client'

import { Button, Input, Select, StatusBadge, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui'
import TableCard from '@/components/admin/TableCard'
import { createTerm, setCurrentTerm, updateTerm } from '@/lib/data/catalog-actions'
import type { CatalogTerm } from '@/lib/data/catalog'
import { SEMESTERS } from '@/lib/data/catalog-validate'
import { CATALOG_MUTED, FormPanel, Notice, useCatalogAction, usePanel } from './CatalogParts'

function TermForm({ term, onClose, onDone }: { term: CatalogTerm | null; onClose: () => void; onDone: (m: string) => void }) {
  const [state, formAction, pending] = useCatalogAction(term ? updateTerm : createTerm, onDone)
  return (
    <FormPanel
      title={term ? `Edit ${term.label}` : 'Add a term'}
      formAction={formAction}
      pending={pending}
      state={state}
      onCancel={onClose}
      submitLabel={term ? 'Save term' : 'Add term'}
    >
      {term && <input type="hidden" name="termId" value={term.id} />}
      <Input id="term-year" name="schoolYear" label="School year" placeholder="2026-2027" maxLength={9} required defaultValue={term?.schoolYear ?? ''} />
      <Select id="term-semester" name="semester" label="Semester" required defaultValue={term?.semester ?? '1st'}>
        {SEMESTERS.map((s) => (
          <option key={s} value={s}>
            {s}
          </option>
        ))}
      </Select>
      <Input id="term-start" name="startDate" type="date" label="Start date" required defaultValue={term?.startDate ?? ''} />
      <Input id="term-end" name="endDate" type="date" label="End date" required defaultValue={term?.endDate ?? ''} />
    </FormPanel>
  )
}

// "Make current" for one row: its own small form (never inside another form).
function MakeCurrent({ term, onResult }: { term: CatalogTerm; onResult: (m: string, ok: boolean) => void }) {
  const [, formAction, pending] = useCatalogAction(async (prev, fd) => {
    const result = await setCurrentTerm(prev, fd)
    onResult(result.message, result.status === 'success')
    return result
  })
  return (
    <form action={formAction}>
      <input type="hidden" name="termId" value={term.id} />
      <Button type="submit" variant="outline" disabled={pending} aria-label={`Make ${term.label} the current term`}>
        {pending ? 'Changing...' : 'Make current'}
      </Button>
    </form>
  )
}

export function CatalogTerms({ terms }: { terms: CatalogTerm[] }) {
  const panel = usePanel<CatalogTerm>()
  const editing = typeof panel.mode === 'object' ? panel.mode.edit : null

  return (
    <div className="flex flex-col gap-3">
      <TableCard
        title="Terms"
        description="Only one term is current. Students can enrol only in sections of the current term."
        action={
          <Button variant="outline" onClick={panel.openAdd}>
            Add term
          </Button>
        }
        minWidth="min-w-[680px]"
      >
        <TableHeader>
          <TableRow className="hover:bg-transparent">
            {['School year', 'Semester', 'Start', 'End', 'Status', 'Actions'].map((c) => (
              <TableHead key={c} scope="col">
                {c}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {terms.length === 0 && (
            <TableRow>
              <TableCell colSpan={6} className="py-8 text-center text-muted">
                No terms yet. Add the first term.
              </TableCell>
            </TableRow>
          )}
          {terms.map((t) => (
            <TableRow key={t.id}>
              <TableCell>{t.schoolYear}</TableCell>
              <TableCell className={CATALOG_MUTED}>{t.semester}</TableCell>
              <TableCell className={`whitespace-nowrap ${CATALOG_MUTED}`}>{t.startDate}</TableCell>
              <TableCell className={`whitespace-nowrap ${CATALOG_MUTED}`}>{t.endDate}</TableCell>
              <TableCell>
                <StatusBadge status={t.isCurrent ? 'Current' : 'Not current'} />
              </TableCell>
              <TableCell>
                <div className="flex flex-wrap items-center gap-2">
                  <Button variant="ghost" onClick={() => panel.openEdit(t)} aria-label={`Edit ${t.label}`}>
                    Edit
                  </Button>
                  {!t.isCurrent && <MakeCurrent term={t} onResult={panel.report} />}
                </div>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </TableCard>
      {panel.mode !== 'closed' && (
        <TermForm key={editing ? `e${editing.id}` : 'add'} term={editing} onClose={panel.close} onDone={panel.done} />
      )}
      <Notice text={panel.notice.text} tone={panel.notice.ok ? 'success' : 'error'} />
    </div>
  )
}
