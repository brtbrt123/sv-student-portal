// Database error to plain-language message for the Academic setup screen. Pure: no database, no session.
// Known errors are matched on the SQLSTATE (and the constraint name in the message when there is one);
// anything unknown gets a generic message with no table names and no raw database text.

export const CATALOG_NOT_ALLOWED = 'Your account is not allowed to change the academic setup.'
export const CATALOG_GENERIC = 'We could not save the change. Please try again in a few minutes.'

export function catalogErrorMessage(code: string | undefined, message: string | undefined): string {
  const text = message ?? ''
  if (code === '42501') return CATALOG_NOT_ALLOWED
  if (code === '23505') {
    if (text.includes('uq_terms_one_current_term')) return 'Another term is already marked as the current term.'
    if (text.includes('terms')) return 'That school year and semester already exist.'
    if (text.includes('_name_key')) return 'That name is already used. Use a different name.'
    return 'That code is already used. Use a different code.'
  }
  if (code === '23514') {
    if (text.includes('terms_dates_order') || text.includes('start_date')) return 'The end date must be after the start date.'
    if (text.includes('capacity')) return 'Capacity must be a whole number above 0.'
    if (text.includes('units')) return 'Units must be a whole number from 0 to 6.'
    if (text.includes('school_year')) return 'Write the school year like 2026-2027.'
    if (text.includes('semester')) return 'Choose the semester: 1st, 2nd or Summer.'
    return 'Some values were not accepted. Please check the form.'
  }
  if (code === '23503') return 'The department, subject or term you chose could not be found. Reload the page.'
  if (code === 'P0001' && text) return 'The change was refused by the database rules. Reload the page and check the values.'
  return CATALOG_GENERIC
}
