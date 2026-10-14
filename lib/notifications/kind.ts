import type { IconName } from '@/lib/nav'

// Which icon goes with a notification kind (the kind codes come from the database triggers). Unknown kinds
// get the plain bell, so a new kind never breaks the list.
const BY_PREFIX: [prefix: string, icon: IconName][] = [
  ['queue_', 'queue'],
  ['enrollment_', 'enrollment'],
  ['application_', 'users'],
  ['document_', 'documents'],
  ['clearance_', 'clearance'],
  ['hold_', 'holds'],
  ['grade_', 'grades'],
]

export function kindIcon(kind: string): IconName {
  return BY_PREFIX.find(([prefix]) => kind.startsWith(prefix))?.[1] ?? 'notifications'
}
