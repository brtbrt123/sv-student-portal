'use client'

import { Button, Input, Select, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui'
import TableCard from '@/components/admin/TableCard'
import { createProgram, updateProgram } from '@/lib/data/catalog-actions'
import type { CatalogDepartment, CatalogProgram } from '@/lib/data/catalog'
import { CATALOG_MUTED, FixedValue, FormPanel, Notice, useCatalogAction, usePanel } from './CatalogParts'

function ProgramForm({
  program,
  departments,
  onClose,
  onDone,
}: {
  program: CatalogProgram | null
  departments: CatalogDepartment[]
  onClose: () => void
  onDone: (m: string) => void
}) {
  const [state, formAction, pending] = useCatalogAction(program ? updateProgram : createProgram, onDone)
  return (
    <FormPanel
      title={program ? `Edit ${program.code}` : 'Add a program'}
      formAction={formAction}
      pending={pending}
      state={state}
      onCancel={onClose}
      submitLabel={program ? 'Save program' : 'Add program'}
    >
      {program && <input type="hidden" name="programId" value={program.id} />}
      <Input id="program-code" name="code" label="Program code" maxLength={20} required defaultValue={program?.code ?? ''} />
      <Input id="program-name" name="name" label="Program name" maxLength={120} required defaultValue={program?.name ?? ''} />
      {program ? (
        <FixedValue label="Department" value={program.departmentName} />
      ) : (
        <Select id="program-dept" name="departmentId" label="Department" required defaultValue="">
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

export function CatalogPrograms({ programs, departments }: { programs: CatalogProgram[]; departments: CatalogDepartment[] }) {
  const panel = usePanel<CatalogProgram>()
  const editing = typeof panel.mode === 'object' ? panel.mode.edit : null

  return (
    <div className="flex flex-col gap-3">
      <TableCard
        title="Programs"
        action={
          <Button variant="outline" onClick={panel.openAdd}>
            Add program
          </Button>
        }
        minWidth="min-w-[600px]"
      >
        <TableHeader>
          <TableRow className="hover:bg-transparent">
            {['Code', 'Program', 'Department', 'Actions'].map((c) => (
              <TableHead key={c} scope="col">
                {c}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {programs.length === 0 && (
            <TableRow>
              <TableCell colSpan={4} className="py-8 text-center text-muted">
                No programs yet.
              </TableCell>
            </TableRow>
          )}
          {programs.map((p) => (
            <TableRow key={p.id}>
              <TableCell>{p.code}</TableCell>
              <TableCell className={CATALOG_MUTED}>{p.name}</TableCell>
              <TableCell className={CATALOG_MUTED}>{p.departmentName}</TableCell>
              <TableCell>
                <Button variant="ghost" onClick={() => panel.openEdit(p)} aria-label={`Edit program ${p.code}`}>
                  Edit
                </Button>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </TableCard>
      {panel.mode !== 'closed' && (
        <ProgramForm
          key={editing ? `e${editing.id}` : 'add'}
          program={editing}
          departments={departments}
          onClose={panel.close}
          onDone={panel.done}
        />
      )}
      <Notice text={panel.notice.text} tone={panel.notice.ok ? 'success' : 'error'} />
    </div>
  )
}
