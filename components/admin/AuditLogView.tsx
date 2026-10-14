'use client'

import { useId, useMemo, useState } from 'react'
import TableCard from '@/components/admin/TableCard'
import {
  Badge,
  Button,
  EmptyRow,
  Input,
  Select,
  SummaryStrip,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui'
import { csvCell } from '@/lib/csv'
import type { AuditEntry } from '@/lib/data/audit'

const ACTION_TONE = { Insert: 'success', Update: 'warning', Delete: 'danger' } as const

// Read-only view of the append-only audit log: no edit or delete controls exist here.
// Search and the action filter run in the browser over the loaded page of entries (the latest
// ones); `total` is the full count in the database.
export default function AuditLogView({ entries, total }: { entries: AuditEntry[]; total: number }) {
  const uid = useId()
  const [action, setAction] = useState('')
  const [query, setQuery] = useState('')

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase()
    return entries.filter(
      (r) =>
        (!action || r.action === action) &&
        (!q || [r.actor, r.table, r.rawTable, r.record, r.details, r.action].some((v) => v.toLowerCase().includes(q)))
    )
  }, [entries, action, query])

  const count = (a: string) => entries.filter((r) => r.action === a).length
  const partial = entries.length < total
  const moreNote = partial
    ? ` Only the latest ${entries.length} of ${total} entries are loaded; search and filters apply to those.`
    : ''
  const summary = `Showing ${visible.length} of ${entries.length} loaded entries. The log cannot be edited or deleted.${moreNote}`

  function exportCsv() {
    const head = ['Time', 'Actor', 'Action', 'Table', 'Raw table', 'Record', 'Details']
    const lines = [
      head,
      ...visible.map((r) => [r.when, r.actor, r.action, r.table, r.rawTable, r.record, r.details]),
    ]
    const csv = lines.map((l) => l.map(csvCell).join(',')).join('\r\n')
    const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }))
    const a = document.createElement('a')
    a.href = url
    a.download = 'audit-log.csv'
    a.click()
    URL.revokeObjectURL(url)
  }

  return (
    <div className="flex flex-col gap-6">
      <SummaryStrip
        items={[
          { label: 'Entries', value: total, hint: partial ? `latest ${entries.length} loaded` : 'recorded so far' },
          { label: 'Inserts', value: count('Insert'), hint: 'in loaded entries', hue: 'teal' },
          { label: 'Updates', value: count('Update'), hint: 'in loaded entries', hue: 'amber' },
          { label: 'Deletes', value: count('Delete'), hint: 'in loaded entries' },
        ]}
      />

      <div className="flex flex-col gap-3">
        <div className="flex flex-wrap items-end gap-3 border-b border-edge pb-4">
          <div className="min-w-[200px] flex-1">
            <Input
              id={`${uid}-search`}
              label="Search entries"
              type="search"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
          </div>
          <div className="w-full sm:w-48">
            <Select id={`${uid}-action`} label="Action" value={action} onChange={(e) => setAction(e.target.value)}>
              <option value="">All actions</option>
              <option value="Insert">Insert</option>
              <option value="Update">Update</option>
              <option value="Delete">Delete</option>
            </Select>
          </div>
          <Button variant="outline" onClick={exportCsv} className="max-sm:w-full" disabled={visible.length === 0}>
            Export CSV
          </Button>
        </div>

        {/* Phone: one hairline list, one entry per block. */}
        <ul className="divide-y divide-edge overflow-hidden rounded-lg border border-edge bg-card md:hidden">
          {visible.length === 0 && (
            <li className="px-4 py-8 text-center text-sm text-muted">No entries match.</li>
          )}
          {visible.map((r) => (
            <li key={r.id} className="flex flex-col gap-1 break-words px-4 py-3">
              <div className="flex items-start justify-between gap-2">
                <p className="font-semibold">{r.actor}</p>
                <Badge tone={ACTION_TONE[r.action]}>{r.action}</Badge>
              </div>
              <p className="text-sm text-muted">{r.when}</p>
              <p className="text-sm">
                <span className="text-muted">Table:</span> {r.table}{' '}
                <span className="text-muted">({r.rawTable})</span>
              </p>
              <p className="text-sm">
                <span className="text-muted">Record:</span> {r.record}
              </p>
              <p className="text-sm">
                <span className="text-muted">Details:</span> {r.details}
              </p>
            </li>
          ))}
        </ul>
        <p className="text-sm text-muted md:hidden" aria-live="polite">
          {summary}
        </p>

        <div className="max-md:hidden">
          <TableCard title="Entries" minWidth="min-w-[960px]" footer={summary}>
            <TableHeader>
              <TableRow className="hover:bg-transparent">
                <TableHead scope="col">Time</TableHead>
                <TableHead scope="col">Actor</TableHead>
                <TableHead scope="col">Action</TableHead>
                <TableHead scope="col">Table</TableHead>
                <TableHead scope="col">Record</TableHead>
                <TableHead scope="col">Details</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {visible.length === 0 && <EmptyRow colSpan={6}>No entries match.</EmptyRow>}
              {visible.map((r) => (
                <TableRow key={r.id}>
                  <TableCell className="whitespace-nowrap font-normal text-muted">{r.when}</TableCell>
                  <TableCell>{r.actor}</TableCell>
                  <TableCell>
                    <Badge tone={ACTION_TONE[r.action]}>{r.action}</Badge>
                  </TableCell>
                  <TableCell className="font-normal text-muted">
                    {r.table}
                    <span className="block text-xs">{r.rawTable}</span>
                  </TableCell>
                  <TableCell className="font-normal text-muted">{r.record}</TableCell>
                  <TableCell className="max-w-[28rem] break-words font-normal text-muted">{r.details}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </TableCard>
        </div>
        <p className="sr-only" role="status">
          {visible.length} entries shown
        </p>
      </div>
    </div>
  )
}
