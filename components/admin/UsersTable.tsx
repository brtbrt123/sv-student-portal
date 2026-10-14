'use client'

import { useActionState, useId, useMemo, useState } from 'react'
import TableCard from '@/components/admin/TableCard'
import {
  Button,
  Section,
  EmptyRow,
  HUE_SOFT,
  HUE_TEXT,
  Input,
  Select,
  SummaryStrip,
  StatusBadge,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui'
import {
  createStaffAccount,
  resendStaffInvite,
  setUserActive,
  updateUserAccount,
  type AdminUserActionState,
} from '@/lib/data/admin-users-actions'
import { departmentTypeFor, type AdminDepartment, type AdminUserRow } from '@/lib/data/admin-users-map'

export type UserRow = AdminUserRow

type UserAction = (prev: AdminUserActionState, formData: FormData) => Promise<AdminUserActionState>

const IDLE: AdminUserActionState = { status: 'idle', message: '' }

function RoleChip({ role }: { role: string }) {
  const tone = role === 'Student' ? `${HUE_SOFT.violet} ${HUE_TEXT.violet}` : 'bg-neutral-soft text-neutral'
  return (
    <span className={`inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium ${tone}`}>
      {role}
    </span>
  )
}

const MESSAGE_TONE: Record<'success' | 'warning' | 'error', string> = {
  success: 'border-edge bg-success-soft text-success',
  warning: 'border-edge bg-warning-soft text-warning',
  error: 'border-edge bg-danger-soft text-danger',
}

// The result of the last action: errors are announced at once (role=alert), the rest politely.
function Notice({ state }: { state: AdminUserActionState }) {
  if (state.status === 'idle' || !state.message) return <p role="status" className="sr-only" />
  return (
    <p
      role={state.status === 'error' ? 'alert' : 'status'}
      className={`rounded-lg border px-4 py-3 text-sm font-medium ${MESSAGE_TONE[state.status]}`}
    >
      {state.message}
    </p>
  )
}

// One button that runs one server action for one account (deactivate, reactivate, resend invite).
// The result goes up to the page-level notice, because the row may move or vanish after a refresh.
function RowAction({
  action,
  fields,
  onResult,
  variant,
  label,
  children,
}: {
  action: UserAction
  fields: Record<string, string>
  onResult: (state: AdminUserActionState) => void
  variant: 'outline' | 'accent' | 'danger'
  label: string
  children: React.ReactNode
}) {
  const [, formAction, pending] = useActionState<AdminUserActionState, FormData>(async (prev, formData) => {
    const result = await action(prev, formData)
    onResult(result)
    return result
  }, IDLE)
  return (
    <form action={formAction}>
      {Object.entries(fields).map(([name, value]) => (
        <input key={name} type="hidden" name={name} value={value} />
      ))}
      <Button type="submit" variant={variant} disabled={pending} aria-label={label}>
        {pending ? 'Working...' : children}
      </Button>
    </form>
  )
}

// The add / edit form. Add creates a staff account (students come from accepted applications);
// Edit changes name, role and department. An error stays in the form; success and warning close it
// and show the message at the top of the page.
function UserForm({
  user,
  staffRoles,
  departments,
  onDone,
  onCancel,
}: {
  user: UserRow | null
  staffRoles: string[]
  departments: AdminDepartment[]
  onDone: (state: AdminUserActionState) => void
  onCancel: () => void
}) {
  const uid = useId()
  const isStudent = user?.role === 'Student'
  const [role, setRole] = useState(user?.role ?? staffRoles[0] ?? 'Registrar')
  const [state, formAction, pending] = useActionState<AdminUserActionState, FormData>(async (prev, formData) => {
    const result = await (user ? updateUserAccount : createStaffAccount)(prev, formData)
    if (result.status === 'success' || result.status === 'warning') onDone(result)
    return result
  }, IDLE)

  const need = departmentTypeFor(role)
  const options = departments.filter((d) => d.type === need)
  const roleOptions = isStudent ? ['Student'] : staffRoles
  const currentDept = user?.departmentId != null && options.some((d) => d.id === user.departmentId) ? String(user.departmentId) : ''

  return (
    <Section title={user ? 'Edit user' : 'Add staff user'}>
      <form action={formAction} className="rounded-lg border border-edge bg-card p-4 lg:p-5">
        {user && <input type="hidden" name="userId" value={user.id} />}
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <Input id={`${uid}-first`} name="firstName" label="First name" defaultValue={user?.firstName ?? ''} maxLength={80} required autoComplete="off" />
          <Input id={`${uid}-last`} name="lastName" label="Last name" defaultValue={user?.lastName ?? ''} maxLength={80} required autoComplete="off" />
          {user ? (
            <div className="flex flex-col gap-1.5">
              <span className="text-[13px] leading-5 font-medium text-foreground">Email</span>
              <p className="break-all py-2 text-sm text-muted">{user.email}</p>
            </div>
          ) : (
            <Input id={`${uid}-email`} name="email" type="email" label="Email" maxLength={254} required autoComplete="off" />
          )}
          <Select id={`${uid}-role`} name={isStudent ? undefined : 'role'} label="Role" value={role} onChange={(e) => setRole(e.target.value)} disabled={isStudent}>
            {roleOptions.map((r) => (
              <option key={r} value={r}>
                {r}
              </option>
            ))}
          </Select>
          {/* A disabled select does not submit, so a Student keeps the role through a hidden field. */}
          {isStudent && <input type="hidden" name="role" value="Student" />}
          {need && (
            <Select
              key={need}
              id={`${uid}-dept`}
              name="departmentId"
              label={need === 'Financial' ? 'Finance department' : 'Academic department'}
              defaultValue={currentDept}
              required
            >
              <option value="">Choose a department</option>
              {options.map((d) => (
                <option key={d.id} value={d.id}>
                  {d.name}
                </option>
              ))}
            </Select>
          )}
        </div>
        {isStudent && (
          <p className="mt-3 text-sm text-muted">A Student account keeps the Student role. Its program is set from the application.</p>
        )}
        {!user && (
          <p className="mt-3 text-sm text-muted">A one-time set-password link is emailed to the new staff member. Students are created from accepted applications.</p>
        )}
        {state.status === 'error' && (
          <p role="alert" className="mt-3 text-sm text-danger">
            {state.message}
          </p>
        )}
        <div className="mt-4 flex flex-wrap gap-2">
          <Button type="submit" disabled={pending}>
            {pending ? 'Saving...' : user ? 'Save changes' : 'Create account'}
          </Button>
          <Button type="button" variant="outline" onClick={onCancel} disabled={pending}>
            Cancel
          </Button>
        </div>
      </form>
    </Section>
  )
}

// Live: the list comes from the database (read with the Admin's own session) and every action calls
// a server action, which refreshes the page data. Accounts are deactivated, never deleted.
export default function UsersTable({
  users,
  roleNames,
  departments,
  currentUserId,
}: {
  users: UserRow[]
  roleNames: string[]
  departments: AdminDepartment[]
  currentUserId: string
}) {
  const uid = useId()
  const [editing, setEditing] = useState<UserRow | 'new' | null>(null)
  const [notice, setNotice] = useState<AdminUserActionState>(IDLE)
  const [query, setQuery] = useState('')
  const [roleFilter, setRoleFilter] = useState('')

  const staffRoles = roleNames.filter((r) => r !== 'Student')
  const students = users.filter((u) => u.role === 'Student')
  const staff = users.filter((u) => u.role !== 'Student')
  const inactive = users.filter((u) => !u.active).length

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase()
    return users.filter(
      (u) =>
        (!roleFilter || u.role === roleFilter) &&
        (!q || u.name.toLowerCase().includes(q) || u.email.toLowerCase().includes(q))
    )
  }, [users, query, roleFilter])

  const rowActions = (u: UserRow) => (
    <div className="flex flex-wrap gap-2">
      <Button
        variant="outline"
        onClick={() => {
          setNotice(IDLE)
          setEditing(u)
        }}
        aria-label={`Edit ${u.name}`}
      >
        Edit
      </Button>
      {u.id === currentUserId ? (
        <span className="inline-flex items-center px-2 text-sm text-muted max-lg:min-h-11">This is you</span>
      ) : (
        <RowAction
          action={setUserActive}
          fields={{ userId: u.id, active: u.active ? 'false' : 'true' }}
          onResult={setNotice}
          variant={u.active ? 'danger' : 'accent'}
          label={`${u.active ? 'Deactivate' : 'Reactivate'} ${u.name}`}
        >
          {u.active ? 'Deactivate' : 'Reactivate'}
        </RowAction>
      )}
      {u.role !== 'Student' && u.active && (
        <RowAction
          action={resendStaffInvite}
          fields={{ userId: u.id }}
          onResult={setNotice}
          variant="outline"
          label={`Resend the set-password link to ${u.name}`}
        >
          Resend invite
        </RowAction>
      )}
    </div>
  )

  return (
    <div className="flex flex-col gap-6">
      <SummaryStrip
        items={[
          { label: 'Total users', value: users.length, hint: 'accounts' },
          { label: 'Active students', value: students.filter((u) => u.active).length, hint: 'can sign in', hue: 'teal' },
          { label: 'Staff', value: staff.length, hint: staffRoles.map((r) => r.toLowerCase()).join(', ') },
          { label: 'Inactive', value: inactive, hint: 'deactivated' },
        ]}
      />

      <Notice state={notice} />

      {editing && (
        <UserForm
          key={editing === 'new' ? 'new' : editing.id}
          user={editing === 'new' ? null : editing}
          staffRoles={staffRoles}
          departments={departments}
          onDone={(state) => {
            setNotice(state)
            setEditing(null)
          }}
          onCancel={() => setEditing(null)}
        />
      )}

      <div className="flex flex-wrap items-end gap-3 border-b border-edge pb-4">
        <div className="min-w-[200px] flex-1">
          <Input
            id={`${uid}-search`}
            label="Search accounts"
            type="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>
        <div className="w-full sm:w-48">
          <Select id={`${uid}-filter`} label="Role" value={roleFilter} onChange={(e) => setRoleFilter(e.target.value)}>
            <option value="">All roles</option>
            {roleNames.map((r) => (
              <option key={r} value={r}>
                {r}
              </option>
            ))}
          </Select>
        </div>
        <Button
          onClick={() => {
            setNotice(IDLE)
            setEditing('new')
          }}
          className="max-sm:w-full"
        >
          Add staff user
        </Button>
      </div>

      {/* Phone: one hairline list, one account per block. */}
      <ul className="-mt-3 divide-y divide-edge overflow-hidden rounded-lg border border-edge bg-card md:hidden">
        {visible.length === 0 && <li className="px-4 py-8 text-center text-sm text-muted">No accounts match.</li>}
        {visible.map((u) => (
          <li key={u.id} className="flex flex-col gap-3 px-4 py-3">
            <div className="flex items-start justify-between gap-2">
              <div className="min-w-0">
                <p className="font-semibold">{u.name}</p>
                <p className="break-all text-sm text-muted">{u.email}</p>
              </div>
              <StatusBadge status={u.active ? 'Active' : 'Inactive'} />
            </div>
            <div className="flex flex-wrap items-center gap-2 text-sm text-muted">
              <RoleChip role={u.role} />
              <span>
                {u.role === 'Student' ? 'Program' : 'Department'}: {u.department}
              </span>
              <span>Created {u.created}</span>
            </div>
            {rowActions(u)}
          </li>
        ))}
      </ul>

      {/* Tablet and desktop: table. */}
      <div className="-mt-3 max-md:hidden">
        <TableCard
          minWidth="min-w-[860px]"
          footer={`Showing ${visible.length} of ${users.length} users. Accounts are deactivated, never deleted.`}
        >
          <TableHeader>
            <TableRow className="hover:bg-transparent">
              <TableHead scope="col">Email</TableHead>
              <TableHead scope="col">Name</TableHead>
              <TableHead scope="col">Role</TableHead>
              <TableHead scope="col">Department or program</TableHead>
              <TableHead scope="col">Status</TableHead>
              <TableHead scope="col">Created</TableHead>
              <TableHead scope="col">Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {visible.length === 0 && <EmptyRow colSpan={7}>No accounts match.</EmptyRow>}
            {visible.map((u) => (
              <TableRow key={u.id}>
                <TableCell className="font-normal text-muted">{u.email}</TableCell>
                <TableCell>{u.name}</TableCell>
                <TableCell>
                  <RoleChip role={u.role} />
                </TableCell>
                <TableCell className="font-normal text-muted">{u.department}</TableCell>
                <TableCell>
                  <StatusBadge status={u.active ? 'Active' : 'Inactive'} />
                </TableCell>
                <TableCell className="whitespace-nowrap font-normal text-muted">{u.created}</TableCell>
                <TableCell>{rowActions(u)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </TableCard>
      </div>
    </div>
  )
}
