import DashboardShell from '@/components/layout/DashboardShell'
import { EmptyState } from '@/components/ui'
import UsersTable from '@/components/admin/UsersTable'
import { requireRole } from '@/lib/auth/session'
import { getAdminUsersState } from '@/lib/data/admin-users'

export default async function AdminUsersPage() {
  const profile = await requireRole('Admin')
  const state = await getAdminUsersState()

  return (
    <DashboardShell profile={profile} title="Users" subtitle="Accounts and roles: users are deactivated, never deleted">
      {state.kind === 'error' ? (
        <EmptyState title="The accounts could not be loaded">
          Something went wrong while reading the accounts. Reload the page in a few minutes.
        </EmptyState>
      ) : (
        <UsersTable
          users={state.users}
          roleNames={state.roleNames}
          departments={state.departments}
          currentUserId={profile.id}
        />
      )}
    </DashboardShell>
  )
}
