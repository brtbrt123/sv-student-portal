// Database error to plain-language message, one function per data layer. Pure: no database, no session, no
// server-only code, so it can be unit tested. Known errors are matched on the SQLSTATE and a stable message
// prefix written by the database triggers; anything unknown gets a generic message (no table names, no raw
// database text). The Server Actions in lib/data/*-actions.ts import these.

export const NOT_ALLOWED = 'Your account is not allowed to do this.'
const GENERIC_DECISION = 'We could not save the decision. Please try again in a few minutes.'
const GENERIC_GRADE = 'We could not save the grade. Please try again in a few minutes.'
const GENERIC_DOCUMENT_UPDATE = 'We could not update this request. Please try again in a few minutes.'
const GENERIC_DEPARTMENT = 'Something went wrong on our side. Please try again in a few minutes.'

const NOT_APPROVED =
  "This grade cannot be saved because the student's enrollment is not approved. Approve the enrollment first, then encode the grade."

// Grades (Registrar).
export function gradeErrorMessage(error: { code?: string; message: string }): string {
  if (error.code === 'P0001' && error.message.startsWith('not approved:')) return NOT_APPROVED
  if (error.code === '23503') return 'That grade is not on the grade scale. Pick a grade from the list.'
  return GENERIC_GRADE
}

// Document requests (Registrar status changes).
export function documentStatusErrorMessage(code: string | undefined, message: string | undefined): string {
  if (code === 'P0001' && message?.startsWith('bad status change:')) {
    return 'That status change is not allowed. Requests move one step at a time, and Released or Rejected requests are final. Reload the page.'
  }
  if (code === '42501') return NOT_ALLOWED
  return GENERIC_DOCUMENT_UPDATE
}

// The student's own enrollment: submit, add a section, remove a section. `generic` is the fallback text of the action.
export function enrollmentErrorMessage(code: string | undefined, message: string | undefined, generic: string): string {
  if (code === '42501') return NOT_ALLOWED
  if (code === 'P0001') {
    if (message?.startsWith('enrollment exists:')) return 'You already have an enrollment for this term. Reload the page.'
    if (message?.startsWith('enrollment locked:')) {
      return 'This enrollment is no longer Pending, so its sections cannot be changed. Reload the page.'
    }
    if (message?.startsWith('wrong term:')) return 'That section is not part of the current term.'
    if (message?.startsWith('duplicate section:')) return 'That section is already in your enrollment. Reload the page.'
  }
  return generic
}

// The Registrar's enrollment decision (approve or reject).
export function enrollmentDecisionErrorMessage(
  code: string | undefined,
  message: string | undefined,
  details: string | null | undefined
): string {
  if (code === 'P0001' && message) {
    if (message.startsWith('section full:')) {
      const list = details?.replace(/^full sections:\s*/, '').slice(0, 400)
      return list
        ? `This enrollment cannot be approved because a section has no seat left. Full sections: ${list}. Ask the student to pick another section, or reject the enrollment.`
        : 'This enrollment cannot be approved because a section has no seat left.'
    }
    if (message.startsWith('no items:')) {
      return 'This enrollment has no sections, so it cannot be approved. Reject it, or wait until the student adds sections.'
    }
    if (message.startsWith('wrong term:')) {
      return 'A section in this enrollment belongs to another term, so it cannot be approved. Reject it so the student can be told.'
    }
    if (message.startsWith('enrollment locked:')) {
      return 'This enrollment was already decided and cannot be changed. Reload the page.'
    }
  }
  if (code === '42501') return NOT_ALLOWED
  return GENERIC_DECISION
}

// The Registrar's decision on a new-student application (accept or reject).
export function applicationDecisionErrorMessage(code: string | undefined, message: string | undefined): string {
  if (code === 'P0001' && message) {
    if (message.startsWith('remarks required:')) return 'Add a remark that tells the applicant why the application is rejected.'
    if (message.startsWith('bad decision:')) return 'This application was already decided and cannot be changed. Reload the page.'
  }
  if (code === '42501') return NOT_ALLOWED
  return GENERIC_DECISION
}

type DbError = { code?: string; message?: string }

// Department head: approving a clearance item. `who` is the student's name.
export function departmentApproveErrorMessage(error: DbError, who: string): string {
  const message = error.message ?? ''
  if (error.code === 'P0001' && message.startsWith('active hold:')) {
    return `${who} has an active hold from your department. Lift the hold first, then approve this item.`
  }
  if (error.code === '42501') return 'You can only approve items that belong to your own department.'
  return GENERIC_DEPARTMENT
}

// Department head: placing a hold.
export function departmentHoldErrorMessage(error: DbError): string {
  if (error.code === '42501') return 'You can only place holds on students of your own department.'
  if (error.code === '23503') return 'That student could not be found.'
  if (error.code === '23514') return 'Enter the reason for the hold.'
  return GENERIC_DEPARTMENT
}

// Department head: rejecting (reviewing) an item, and lifting a hold. Only a permission error is named.
export function departmentReviewErrorMessage(code: string | undefined): string {
  return code === '42501' ? 'You can only review items of your own department.' : GENERIC_DEPARTMENT
}

export function departmentLiftHoldErrorMessage(code: string | undefined): string {
  return code === '42501' ? 'You can only lift holds placed by your own department.' : GENERIC_DEPARTMENT
}

// Cashier: recording a payment. `fieldErrors` says which field of the form the message belongs to.
export function paymentErrorMessage(
  code: string | undefined,
  generic: string
): { message: string; fieldErrors?: { receipt?: string; charge?: string; amount?: string } } {
  if (code === '23505') {
    return { message: 'That receipt number is already used.', fieldErrors: { receipt: 'This receipt number is already used. Use a new one.' } }
  }
  if (code === '42501') return { message: NOT_ALLOWED }
  if (code === '23503') {
    return { message: 'We could not find that charge.', fieldErrors: { charge: 'Choose the charge this payment is for.' } }
  }
  if (code === '23514') {
    return { message: 'Enter an amount greater than 0.', fieldErrors: { amount: 'Enter an amount greater than 0.' } }
  }
  return { message: generic }
}

// Cashier: tagging a charge as paid or waived.
export function chargeTagErrorMessage(code: string | undefined, generic: string): string {
  return code === '42501' ? NOT_ALLOWED : generic
}

// Student: sending a new document request.
export function documentRequestErrorMessage(
  code: string | undefined,
  generic: string
): { message: string; fieldErrors?: { type?: string } } {
  if (code === '42501') return { message: NOT_ALLOWED }
  if (code === '23503') {
    return { message: 'We could not find that document type.', fieldErrors: { type: 'Choose the document you need.' } }
  }
  if (code === '23514') return { message: 'Please check the purpose and the number of copies.' }
  return { message: generic }
}

// Public application form (/apply/enroll). Two rules of the database function are named; the rest is generic.
export function applicationFormErrorMessage(code: string | undefined, message: string | undefined, generic: string): string {
  if (code === '22023' && message?.startsWith('invalid application:')) {
    return 'Some details were not accepted. Please check the form and try again.'
  }
  if (code === 'P0001' && message?.startsWith('try later:')) {
    return 'Applications are busy right now. Please try again in a little while.'
  }
  return generic
}

// Registrar: issuing the final clearance. Returns null for an unknown error, so the action uses its own generic result.
export function finalClearanceErrorMessage(code: string | undefined, message: string | undefined): string | null {
  if (code === 'P0001' && message?.startsWith('pending items:')) {
    return 'An office has not cleared this student yet, so final clearance cannot be issued. Reload to see the latest status.'
  }
  return null
}

// Student: submitting an enrollment (the year level has its own field message).
export function enrollmentSubmitErrorMessage(
  code: string | undefined,
  message: string | undefined,
  generic: string,
  range: { min: number; max: number }
): { message: string; fieldErrors?: { yearLevel?: string } } {
  if (code === '23505') return { message: 'You already have an enrollment for this term. Reload the page.' }
  if (code === '23514') {
    return { message: 'Please check the year level.', fieldErrors: { yearLevel: `Choose a year level from ${range.min} to ${range.max}.` } }
  }
  return { message: enrollmentErrorMessage(code, message, generic) }
}

// Student: adding a section to a Pending enrollment.
export function enrollmentAddSectionErrorMessage(code: string | undefined, message: string | undefined, generic: string): string {
  if (code === '23505') return 'That section is already in your enrollment. Reload the page.'
  if (code === '23503') return 'We could not find that section. Reload the page.'
  return enrollmentErrorMessage(code, message, generic)
}

const GENERIC_QUEUE = 'We could not update the queue. Please try again in a few minutes.'
const TICKET_LABEL_RE = /^#\d{7}$/

// The label in a message such as "already queued: E-014", or null when it does not look like one.
function ticketLabelIn(message: string, prefix: string): string | null {
  const label = message.slice(prefix.length).trim()
  return TICKET_LABEL_RE.test(label) ? label : null
}

// The queue (tickets): issuing a ticket, calling the next one, finishing, cancelling.
export function queueErrorMessage(code: string | undefined, message: string | undefined): string {
  if (code === 'P0001' && message) {
    if (message.startsWith('already queued:')) {
      const label = ticketLabelIn(message, 'already queued:')
      return label ? `This student already has ticket ${label} in the queue.` : 'This student already has a ticket in the queue.'
    }
    if (message.startsWith('finish first:')) {
      const label = ticketLabelIn(message, 'finish first:')
      return `${label ? `Ticket ${label} is` : 'A ticket is'} still being served. Press Done or No-show first, then call the next one.`
    }
    if (message.startsWith('queue closed:')) return 'This queue is closed right now.'
    if (message.startsWith('queue busy:')) return 'The queue is busy for a moment. Please press Approve again.'
    if (message.startsWith('hold active:')) {
      return 'This hold has not run out yet. A held ticket can be marked No-show only after its 30 minutes are over.'
    }
    if (message.startsWith('hold expired:')) {
      return 'Your hold ran out. Cancel this ticket and ask the Registrar for a new number.'
    }
    if (message.startsWith('bad ticket change: no waiting ticket')) return 'You do not have a ticket in the line right now.'
    if (message.startsWith('bad ticket change: no ticket on hold')) return 'Your place is not on hold.'
    if (message.includes('is already on hold')) return 'Your place is already on hold.'
    if (message.includes('cannot be put on hold')) return 'It is your turn now, so your place cannot be put on hold.'
    if (message.includes('can only be marked No-show')) return 'A ticket on hold can only be marked No-show.'
    if (message.startsWith('bad ticket change:')) return 'This ticket was already changed by someone else. Reload the page.'
  }
  if (code === '22023') return 'That is not an active student account, so no ticket was issued.'
  if (code === '42501') return NOT_ALLOWED
  return GENERIC_QUEUE
}
