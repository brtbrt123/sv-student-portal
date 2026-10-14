import { describe, expect, it } from 'vitest'
import {
  NOT_ALLOWED,
  applicationFormErrorMessage,
  chargeTagErrorMessage,
  departmentLiftHoldErrorMessage,
  departmentReviewErrorMessage,
  documentRequestErrorMessage,
  enrollmentAddSectionErrorMessage,
  enrollmentSubmitErrorMessage,
  finalClearanceErrorMessage,
  paymentErrorMessage,
} from '@/lib/data/db-errors'

describe('cashier (UT-42..43)', () => {
  const generic = 'GENERIC PAYMENT'
  it('UT-42 recording a payment: each database rule names its form field', () => {
    expect(paymentErrorMessage('23505', generic)).toEqual({
      message: 'That receipt number is already used.',
      fieldErrors: { receipt: 'This receipt number is already used. Use a new one.' },
    })
    expect(paymentErrorMessage('23503', generic).fieldErrors).toEqual({ charge: 'Choose the charge this payment is for.' })
    expect(paymentErrorMessage('23514', generic).fieldErrors).toEqual({ amount: 'Enter an amount greater than 0.' })
    expect(paymentErrorMessage('42501', generic)).toEqual({ message: NOT_ALLOWED })
  })
  it('UT-43 an unknown payment error returns the generic text with no field, and the charge tag maps 42501 only', () => {
    expect(paymentErrorMessage('XX000', generic)).toEqual({ message: generic })
    expect(chargeTagErrorMessage('42501', 'GENERIC TAG')).toBe(NOT_ALLOWED)
    expect(chargeTagErrorMessage('XX000', 'GENERIC TAG')).toBe('GENERIC TAG')
  })
})

describe('student document request (UT-44)', () => {
  it('UT-44 permission, unknown type (with its field), bad purpose or copies, and unknown error', () => {
    const generic = 'GENERIC REQUEST'
    expect(documentRequestErrorMessage('42501', generic)).toEqual({ message: NOT_ALLOWED })
    expect(documentRequestErrorMessage('23503', generic).fieldErrors).toEqual({ type: 'Choose the document you need.' })
    expect(documentRequestErrorMessage('23514', generic).message).toBe('Please check the purpose and the number of copies.')
    expect(documentRequestErrorMessage('XX000', generic)).toEqual({ message: generic })
  })
})

describe('public application form (UT-45)', () => {
  it('UT-45 invalid details, the flood valve ("try later"), and an unknown error', () => {
    const generic = 'GENERIC APPLY'
    expect(applicationFormErrorMessage('22023', 'invalid application: email', generic)).toBe(
      'Some details were not accepted. Please check the form and try again.'
    )
    expect(applicationFormErrorMessage('P0001', 'try later: too many', generic)).toBe(
      'Applications are busy right now. Please try again in a little while.'
    )
    expect(applicationFormErrorMessage('P0001', 'something else', generic)).toBe(generic)
    expect(applicationFormErrorMessage(undefined, undefined, generic)).toBe(generic)
  })
})

describe('Registrar final clearance (UT-46)', () => {
  it('UT-46 pending items is explained; any other error returns null so the action uses its own generic result', () => {
    expect(finalClearanceErrorMessage('P0001', 'pending items: 2')).toContain('An office has not cleared this student yet')
    expect(finalClearanceErrorMessage('P0001', 'something else')).toBeNull()
    expect(finalClearanceErrorMessage('42501', 'denied')).toBeNull()
  })
})

describe('student enrollment forms (UT-47..48)', () => {
  const range = { min: 1, max: 6 }
  it('UT-47 submitting: already enrolled, bad year level (with its field), a trigger rule, and an unknown error', () => {
    expect(enrollmentSubmitErrorMessage('23505', 'dup', 'GENERIC', range).message).toContain('already have an enrollment')
    expect(enrollmentSubmitErrorMessage('23514', 'check', 'GENERIC', range)).toEqual({
      message: 'Please check the year level.',
      fieldErrors: { yearLevel: 'Choose a year level from 1 to 6.' },
    })
    expect(enrollmentSubmitErrorMessage('P0001', 'wrong term: x', 'GENERIC', range).message).toContain('not part of the current term')
    expect(enrollmentSubmitErrorMessage('XX000', 'boom', 'GENERIC', range)).toEqual({ message: 'GENERIC' })
  })
  it('UT-48 adding a section: duplicate, unknown section, a trigger rule, and an unknown error', () => {
    expect(enrollmentAddSectionErrorMessage('23505', 'dup', 'GENERIC')).toBe('That section is already in your enrollment. Reload the page.')
    expect(enrollmentAddSectionErrorMessage('23503', 'fk', 'GENERIC')).toBe('We could not find that section. Reload the page.')
    expect(enrollmentAddSectionErrorMessage('P0001', 'enrollment locked: x', 'GENERIC')).toContain('no longer Pending')
    expect(enrollmentAddSectionErrorMessage('XX000', 'boom', 'GENERIC')).toBe('GENERIC')
  })
})

describe('department head: review and lift hold (UT-49)', () => {
  it('UT-49 a permission error is named, anything else is generic with no database text', () => {
    expect(departmentReviewErrorMessage('42501')).toBe('You can only review items of your own department.')
    expect(departmentLiftHoldErrorMessage('42501')).toBe('You can only lift holds placed by your own department.')
    const generic = 'Something went wrong on our side. Please try again in a few minutes.'
    expect(departmentReviewErrorMessage('XX000')).toBe(generic)
    expect(departmentLiftHoldErrorMessage(undefined)).toBe(generic)
  })
})
