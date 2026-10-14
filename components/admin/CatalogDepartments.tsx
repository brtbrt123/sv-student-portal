'use client'

import { Button, Input, Select, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui'
import TableCard from '@/components/admin/TableCard'
import { createDepartment, updateDepartment } from '@/lib/data/catalog-actions'
import type { CatalogDepartment } from '@/lib/data/catalog'
import { DEPARTMENT_TYPES } from '@/lib/data/catalog-validate'
import { CATALOG_MUTED, FixedValue, FormPanel, Notice, useCatalogAction, usePanel } from './CatalogParts'

function DepartmentForm({
  department,
  onClose,
  onDone,
}: {
  department: CatalogDepartment | null
  onClose: () => void
  onDone: (m: string) => void
}) {
  const [state, formAction, pending] = useCatalogAction(department ? updateDepartment : createDepartment, onDone)
  return (
    <FormPanel
      title={department ? `Edit ${department.code}` : 'Add a department'}
      formAction={formAction}
      pending={pending}
      state={state}
      onCancel={onClose}
      submitLabel={department ? 'Save department' : 'Add department'}
    >
      {department && <input type="hidden" name="departmentId" value={department.id} />}
      <Input id="department-code" name="code" label="Department code" maxLength={20} required defaultValue={department?.code ?? ''} />
      <Input id="department-name" name="name" label="Department name" maxLength={120} required defaultValue={department?.name ?? ''} />
      {department ? (
        <FixedValue label="Type" value={department.type} />
      ) : (
        <Select id="department-type" name="departmentType" label="Type" required defaultValue="">
          <option value="" disabled>
            Choose a type
          </option>
          {DEPARTMENT_TYPES.map((t) => (
            <option key={t} value={t}>
              {t}
            </option>
          ))}
        </Select>
      )}
    </FormPanel>
  )
}

export function CatalogDepartments({ departments }: { departments: CatalogDepartment[] }) {
  const panel = usePanel<CatalogDepartment>()
  const editing = typeof panel.mode === 'object' ? panel.mode.edit : null

  return (
    <div className="flex flex-col gap-3">
      <TableCard
        title="Departments"
        description="The type (Academic or Financial) is chosen when a department is created and cannot be changed afterwards."
        action={
          <Button variant="outline" onClick={panel.openAdd}>
            Add department
          </Button>
        }
        minWidth="min-w-[480px]"
      >
        <TableHeader>
          <TableRow className="hover:bg-transparent">
            {['Code', 'Name', 'Type', 'Actions'].map((c) => (
              <TableHead key={c} scope="col">
                {c}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {departments.length === 0 && (
            <TableRow>
              <TableCell colSpan={4} className="py-8 text-center text-muted">
                No departments yet.
              </TableCell>
            </TableRow>
          )}
          {departments.map((d) => (
            <TableRow key={d.id}>
              <TableCell>{d.code}</TableCell>
              <TableCell className={CATALOG_MUTED}>{d.name}</TableCell>
              <TableCell className={CATALOG_MUTED}>{d.type}</TableCell>
              <TableCell>
                <Button variant="ghost" onClick={() => panel.openEdit(d)} aria-label={`Edit department ${d.code}`}>
                  Edit
                </Button>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </TableCard>
      {panel.mode !== 'closed' && (
        <DepartmentForm
          key={editing ? `e${editing.id}` : 'add'}
          department={editing}
          onClose={panel.close}
          onDone={panel.done}
        />
      )}
      <Notice text={panel.notice.text} tone={panel.notice.ok ? 'success' : 'error'} />
    </div>
  )
}
