// One CSV cell for the audit log export. Spreadsheet programs run text that starts with = + - @ (or a tab or
// carriage return) as a formula, so such a cell gets a leading apostrophe. Quotes are doubled and the cell is
// always quoted.
export function csvCell(value: string): string {
  const safe = /^[=+\-@\t\r]/.test(value) ? `'${value}` : value
  return `"${safe.replace(/"/g, '""')}"`
}
