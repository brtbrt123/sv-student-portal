import type { RoleName } from '@/lib/auth/roles'
import { ROLE_HOME, ROLES } from '@/lib/auth/roles'

export type IconName =
  | 'dashboard' | 'enrollment' | 'grades' | 'clearance' | 'documents'
  | 'charges' | 'payments' | 'holds' | 'users' | 'setup' | 'audit'
  | 'encode' | 'settings' | 'notifications' | 'queue'

export type NavItem = { label: string; href: string; icon: IconName }

// Sidebar links per role, same as the Figma sidebars. Every href has a page under app/(modules)/.
const BASE_NAV: Record<RoleName, NavItem[]> = {
  Student: [
    { label: 'Dashboard', href: ROLE_HOME.Student, icon: 'dashboard' },
    { label: 'Enrollment', href: '/student/enrollment', icon: 'enrollment' },
    { label: 'Grades', href: '/student/grades', icon: 'grades' },
    { label: 'Clearance', href: '/student/clearance', icon: 'clearance' },
    { label: 'Document Requests', href: '/student/documents', icon: 'documents' },
    { label: 'Queue', href: '/student/queue', icon: 'queue' },
  ],
  Registrar: [
    { label: 'Dashboard', href: ROLE_HOME.Registrar, icon: 'dashboard' },
    { label: 'Encode Grades', href: '/registrar/grades', icon: 'encode' },
    { label: 'Enrollments', href: '/registrar/enrollments', icon: 'enrollment' },
    { label: 'Queue', href: '/registrar/queue', icon: 'queue' },
    { label: 'Applications', href: '/registrar/applications', icon: 'users' },
    { label: 'Clearance', href: '/registrar/clearance', icon: 'clearance' },
    { label: 'Document Requests', href: '/registrar/documents', icon: 'documents' },
  ],
  Cashier: [
    { label: 'Dashboard', href: ROLE_HOME.Cashier, icon: 'dashboard' },
    { label: 'Charges', href: '/cashier/charges', icon: 'charges' },
    { label: 'Payments', href: '/cashier/payments', icon: 'payments' },
    { label: 'Finance Clearance', href: '/cashier/clearance', icon: 'clearance' },
  ],
  Department: [
    { label: 'Dashboard', href: ROLE_HOME.Department, icon: 'dashboard' },
    { label: 'Clearance Items', href: '/department/clearance', icon: 'clearance' },
    { label: 'Academic Holds', href: '/department/holds', icon: 'holds' },
  ],
  Admin: [
    { label: 'Dashboard', href: ROLE_HOME.Admin, icon: 'dashboard' },
    { label: 'Users', href: '/admin/users', icon: 'users' },
    { label: 'Academic Setup', href: '/admin/academic-setup', icon: 'setup' },
    { label: 'Audit Log', href: '/admin/audit-log', icon: 'audit' },
  ],
}

// Every role also gets its Notifications page (/student/notifications, /registrar/notifications, ...) as the
// last link; the shell puts the unread count on it.
export const NAV_ITEMS = Object.fromEntries(
  ROLES.map((role) => [role, [...BASE_NAV[role], { label: 'Notifications', href: `${ROLE_HOME[role]}/notifications`, icon: 'notifications' } satisfies NavItem]])
) as Record<RoleName, NavItem[]>
