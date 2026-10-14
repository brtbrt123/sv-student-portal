import { describe, expect, it } from 'vitest'
import {
  NOT_ALLOWED,
  applicationDecisionErrorMessage,
  departmentApproveErrorMessage,
  departmentHoldErrorMessage,
  documentStatusErrorMessage,
  enrollmentDecisionErrorMessage,
  enrollmentErrorMessage,
  gradeErrorMessage,
} from '@/lib/data/db-errors'

describe('grades: database error to message (UT-27..28)', () => {
  it('UT-27 the "not approved" trigger error tells the Registrar to approve the enrollment first', () => {
    expect(gradeErrorMessage({ code: 'P0001', message: 'not approved: enrollment 12' })).toContain('Approve the enrollment first')
  })
  it('UT-28 a grade that is not on the scale (foreign key) and an unknown error', () => {
    expect(gradeErrorMessage({ code: '23503', message: 'x' })).toBe('That grade is not on the grade scale. Pick a grade from the list.')
    const unknown = gradeErrorMessage({ code: 'XX000', message: 'relation "grades" does not exist' })
    expect(unknown).toBe('We could not save the grade. Please try again in a few minutes.')
    expect(unknown).not.toContain('does not exist') // no raw database text
  })
})

describe('document requests (UT-29..30)', () => {
  it('UT-29 an illegal status change is explained', () => {
    expect(documentStatusErrorMessage('P0001', 'bad status change: Ready -> Pending')).toContain('one step at a time')
  })
  it('UT-30 a permission error and an unknown error', () => {
    expect(documentStatusErrorMessage('42501', 'denied')).toBe(NOT_ALLOWED)
    expect(documentStatusErrorMessage(undefined, undefined)).toBe('We could not update this request. Please try again in a few minutes.')
  })
})

describe('student enrollment (UT-31..33)', () => {
  const generic = 'GENERIC TEXT OF THE ACTION'
  it('UT-31 each trigger rule has its own message', () => {
    expect(enrollmentErrorMessage('P0001', 'enrollment exists: x', generic)).toContain('already have an enrollment')
    expect(enrollmentErrorMessage('P0001', 'enrollment locked: x', generic)).toContain('no longer Pending')
    expect(enrollmentErrorMessage('P0001', 'wrong term: x', generic)).toContain('not part of the current term')
    expect(enrollmentErrorMessage('P0001', 'duplicate section: x', generic)).toContain('already in your enrollment')
  })
  it('UT-32 a permission error is mapped', () => {
    expect(enrollmentErrorMessage('42501', 'denied', generic)).toBe(NOT_ALLOWED)
  })
  it('UT-33 an unknown error returns the text of the action that called it', () => {
    expect(enrollmentErrorMessage('P0001', 'something new: x', generic)).toBe(generic)
    expect(enrollmentErrorMessage('XX000', 'boom', generic)).toBe(generic)
  })
})

describe('Registrar enrollment decision (UT-34..36)', () => {
  it('UT-34 a full section lists the sections that are full', () => {
    const msg = enrollmentDecisionErrorMessage('P0001', 'section full: 2', 'full sections: CS101-A, CS102-B')
    expect(msg).toContain('Full sections: CS101-A, CS102-B.')
  })
  it('UT-35 a full section without details still explains', () => {
    expect(enrollmentDecisionErrorMessage('P0001', 'section full: 1', null)).toBe(
      'This enrollment cannot be approved because a section has no seat left.'
    )
  })
  it('UT-36 other rules, a permission error and an unknown error', () => {
    expect(enrollmentDecisionErrorMessage('P0001', 'no items: 7', null)).toContain('no sections')
    expect(enrollmentDecisionErrorMessage('P0001', 'enrollment locked: 7', null)).toContain('already decided')
    expect(enrollmentDecisionErrorMessage('42501', 'denied', null)).toBe(NOT_ALLOWED)
    expect(enrollmentDecisionErrorMessage('XX000', 'boom', null)).toBe('We could not save the decision. Please try again in a few minutes.')
  })
})

describe('application decision (UT-37)', () => {
  it('UT-37 remarks required, already decided, permission and unknown', () => {
    expect(applicationDecisionErrorMessage('P0001', 'remarks required: reject')).toContain('Add a remark')
    expect(applicationDecisionErrorMessage('P0001', 'bad decision: Accepted')).toContain('already decided')
    expect(applicationDecisionErrorMessage('42501', 'denied')).toBe(NOT_ALLOWED)
    expect(applicationDecisionErrorMessage('XX000', 'boom')).toBe('We could not save the decision. Please try again in a few minutes.')
  })
})

describe('department head (UT-38..39)', () => {
  it('UT-38 approving an item with an active hold names the student', () => {
    expect(departmentApproveErrorMessage({ code: 'P0001', message: 'active hold: 3' }, 'Ana Reyes')).toBe(
      'Ana Reyes has an active hold from your department. Lift the hold first, then approve this item.'
    )
  })
  it('UT-39 placing a hold: other department, unknown student, empty reason, unknown error', () => {
    expect(departmentHoldErrorMessage({ code: '42501' })).toContain('your own department')
    expect(departmentHoldErrorMessage({ code: '23503' })).toBe('That student could not be found.')
    expect(departmentHoldErrorMessage({ code: '23514' })).toBe('Enter the reason for the hold.')
    expect(departmentHoldErrorMessage({ code: 'XX000' })).toBe('Something went wrong on our side. Please try again in a few minutes.')
  })
})
