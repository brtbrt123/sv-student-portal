import Link from 'next/link'
import DashboardShell from '@/components/layout/DashboardShell'
import TableCard from '@/components/admin/TableCard'
import { requireRole } from '@/lib/auth/session'
import {
  Badge,
  EmptyRow,
  EmptyState,
  SummaryStrip,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui'
import { getAdminDashboard } from '@/lib/data/dashboards'

const ACTION_TONE = { Insert: 'success', Update: 'warning', Delete: 'danger' } as const

function CouldNotLoad({ what }: { what: string }) {
  return (
    <div role="alert">
      <EmptyState title={`We could not load ${what}`}>Reload the page. If it keeps happening, come back in a few minutes.</EmptyState>
    </div>
  )
}

export default async function AdminDashboardPage() {
  const profile = await requireRole('Admin')
  const { users, audit } = await getAdminDashboard()
  const ready = users.kind === 'ready'

  return (
    <DashboardShell profile={profile} title="Dashboard" subtitle="Accounts and recent activity">
      <div className="flex flex-col gap-6">
        <SummaryStrip
          items={[
            { label: 'Total users', value: users.kind === 'ready' ? users.totals.total : '-', hint: ready ? 'accounts' : 'could not load' },
            { label: 'Active', value: users.kind === 'ready' ? users.totals.active : '-', hint: ready ? 'can sign in' : 'could not load', hue: ready ? 'teal' : undefined },
            { label: 'Inactive', value: users.kind === 'ready' ? users.totals.inactive : '-', hint: ready ? 'deactivated' : 'could not load' },
            { label: 'Audit entries', value: audit.kind === 'ready' ? audit.total : '-', hint: audit.kind === 'ready' ? 'recorded so far' : 'could not load' },
          ]}
        />

        {users.kind === 'error' ? (
          <CouldNotLoad what="users by role" />
        ) : (
          <TableCard title="Users by role" minWidth="min-w-[420px]">
            <TableHeader>
              <TableRow className="hover:bg-transparent">
                <TableHead scope="col">Role</TableHead>
                <TableHead scope="col">Users</TableHead>
                <TableHead scope="col">Active</TableHead>
                <TableHead scope="col">Inactive</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {users.byRole.length === 0 && <EmptyRow colSpan={4}>No roles found.</EmptyRow>}
              {users.byRole.map((r) => (
                <TableRow key={r.role}>
                  <TableCell>{r.role}</TableCell>
                  <TableCell className="font-normal text-muted">{r.users}</TableCell>
                  <TableCell className="font-normal text-muted">{r.active}</TableCell>
                  <TableCell className="font-normal text-muted">{r.inactive}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </TableCard>
        )}

        {audit.kind === 'error' ? (
          <CouldNotLoad what="the audit log" />
        ) : (
          <TableCard
            title="Recent audit entries"
            action={
              <Link
                href="/admin/audit-log"
                className="inline-flex h-9 items-center rounded-md px-2 text-sm font-semibold text-accent-foreground hover:bg-accent max-lg:h-11 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
              >
                View full log
              </Link>
            }
            minWidth="min-w-[560px]"
          >
            <TableHeader>
              <TableRow className="hover:bg-transparent">
                <TableHead scope="col">Time</TableHead>
                <TableHead scope="col">Actor</TableHead>
                <TableHead scope="col">Action</TableHead>
                <TableHead scope="col">Table</TableHead>
                <TableHead scope="col">Record</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {audit.recent.length === 0 && <EmptyRow colSpan={5}>No audit entries yet.</EmptyRow>}
              {audit.recent.map((log) => (
                <TableRow key={log.id}>
                  <TableCell className="whitespace-nowrap font-normal text-muted">{log.when}</TableCell>
                  <TableCell>{log.actor}</TableCell>
                  <TableCell>
                    <Badge tone={ACTION_TONE[log.action]}>{log.action}</Badge>
                  </TableCell>
                  <TableCell className="font-normal text-muted">{log.table}</TableCell>
                  <TableCell className="font-normal text-muted">{log.record}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </TableCard>
        )}
      </div>
    </DashboardShell>
  )
}
