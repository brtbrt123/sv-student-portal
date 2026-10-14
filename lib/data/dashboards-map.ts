// Pure helpers for the Registrar and Admin dashboards. No database access here, so they are unit tested.

export type StatusCounts<S extends string> = Record<S, number>

/** Counts rows per status; statuses not listed are ignored. */
export function countByStatus<S extends string>(rows: readonly { status: string }[], statuses: readonly S[]): StatusCounts<S> {
  const counts = Object.fromEntries(statuses.map((s) => [s, 0])) as StatusCounts<S>
  for (const r of rows) {
    if ((statuses as readonly string[]).includes(r.status)) counts[r.status as S] += 1
  }
  return counts
}

/** The first n rows that match, in their existing order. */
export function firstWhere<T>(rows: readonly T[], keep: (row: T) => boolean, n: number): T[] {
  const out: T[] = []
  for (const r of rows) {
    if (out.length >= n) break
    if (keep(r)) out.push(r)
  }
  return out
}

export type QueueCounts = { waiting: number; serving: number; held: number }

/** Today's queue numbers from ticket statuses. */
export function queueCounts(tickets: readonly { status: string }[]): QueueCounts {
  const c = countByStatus(tickets, ['Waiting', 'Serving', 'Held'] as const)
  return { waiting: c.Waiting, serving: c.Serving, held: c.Held }
}

export type RoleCountRow = { role: string; users: number; active: number; inactive: number }

export type ProfileCountInput = { role_id: number; is_active: boolean }
export type RoleInput = { role_id: number; role_name: string }

/** Users per role (every known role is listed, even with zero users), in role id order. */
export function roleCounts(profiles: readonly ProfileCountInput[], roles: readonly RoleInput[]): RoleCountRow[] {
  const rows = new Map<number, RoleCountRow>()
  for (const r of [...roles].sort((a, b) => a.role_id - b.role_id)) {
    rows.set(r.role_id, { role: r.role_name, users: 0, active: 0, inactive: 0 })
  }
  for (const p of profiles) {
    const row = rows.get(p.role_id)
    if (!row) continue
    row.users += 1
    if (p.is_active) row.active += 1
    else row.inactive += 1
  }
  return [...rows.values()]
}

export type UserTotals = { total: number; active: number; inactive: number }

export function userTotals(profiles: readonly { is_active: boolean }[]): UserTotals {
  const active = profiles.filter((p) => p.is_active).length
  return { total: profiles.length, active, inactive: profiles.length - active }
}
