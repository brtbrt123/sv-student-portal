'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { getCurrentProfile } from '@/lib/auth/session'
import { formatPeso } from '@/components/cashier/format'
import { paymentErrorMessage, chargeTagErrorMessage } from '@/lib/data/db-errors'

// Server Actions for the Cashier. They run with the signed-in user's own session: the database (RLS,
// column grants, triggers) is the final gate; the checks here only give friendly messages. Dates are
// set by the database (paid_at defaults to now()), never by the browser.

export type LogPaymentState = {
  status: 'idle' | 'success' | 'error'
  message: string
  fieldErrors?: { charge?: string; amount?: string; receipt?: string }
}

export type TagChargeState = { status: 'idle' | 'success' | 'error'; message: string }

const GENERIC_PAYMENT = 'We could not log this payment. Please try again in a few minutes.'
const GENERIC_TAG = 'We could not update this charge. Please try again in a few minutes.'
const SESSION_ENDED = 'Your session has ended. Please sign in again.'

const round2 = (n: number) => Math.round(n * 100) / 100

async function requireCashier() {
  const profile = await getCurrentProfile()
  return profile && profile.role === 'Cashier' ? profile : null
}

// Logs a payment against one charge. Sends only the granted columns: charge_id, amount_paid,
// recorded_by (the signed-in user). paid_at and receipt_number are left out: the database stamps the time
// and numbers the receipt itself (clearance_college_flow.sql).
export async function logPayment(_prev: LogPaymentState, formData: FormData): Promise<LogPaymentState> {
  void _prev
  const err = (message: string, fieldErrors?: LogPaymentState['fieldErrors']): LogPaymentState => ({
    status: 'error',
    message,
    fieldErrors,
  })

  const chargeRaw = String(formData.get('chargeId') ?? '')
  const amountRaw = String(formData.get('amount') ?? '').trim().replace(/,/g, '')

  const fieldErrors: NonNullable<LogPaymentState['fieldErrors']> = {}
  const chargeId = /^\d+$/.test(chargeRaw) ? Number(chargeRaw) : NaN
  if (!Number.isSafeInteger(chargeId)) fieldErrors.charge = 'Choose the charge this payment is for.'
  const amount = /^\d+(\.\d{1,2})?$/.test(amountRaw) ? Number(amountRaw) : NaN
  if (!Number.isFinite(amount) || amount <= 0) fieldErrors.amount = 'Enter an amount greater than 0, with at most 2 decimals.'
  if (Object.keys(fieldErrors).length > 0) return err('Please fix the highlighted fields.', fieldErrors)

  let receipt = ''
  try {
    const profile = await requireCashier()
    if (!profile) return err(SESSION_ENDED)
    const supabase = await createClient()

    const { data: charge, error: chargeError } = await supabase
      .from('charges')
      .select('charge_id, amount, status')
      .eq('charge_id', chargeId)
      .maybeSingle()
    if (chargeError) return err(GENERIC_PAYMENT)
    if (!charge) return err('We could not find that charge.', { charge: 'Choose the charge this payment is for.' })
    if (charge.status !== 'Unpaid') {
      return err(`This charge is already ${charge.status}, so it cannot take a payment.`, {
        charge: `Already ${charge.status}.`,
      })
    }

    const { data: prior, error: priorError } = await supabase
      .from('payments')
      .select('amount_paid')
      .eq('charge_id', chargeId)
    if (priorError) return err(GENERIC_PAYMENT)
    const balance = round2(Number(charge.amount) - (prior ?? []).reduce((s, p) => s + Number(p.amount_paid), 0))
    if (amount > balance) {
      return err('That is more than the student owes on this charge.', {
        amount: `The balance is only ${formatPeso(Math.max(balance, 0))}.`,
      })
    }

    // receipt_number is left out: the database numbers the payment (OR-<year>-<six digits>).
    const { data: inserted, error } = await supabase
      .from('payments')
      .insert({ charge_id: chargeId, amount_paid: amount, recorded_by: profile.id })
      .select('receipt_number')
      .single()
    if (error) {
      const mapped = paymentErrorMessage(error.code, GENERIC_PAYMENT)
      return err(mapped.message, mapped.fieldErrors)
    }
    receipt = inserted?.receipt_number ?? ''
  } catch {
    return err(GENERIC_PAYMENT)
  }

  revalidatePath('/cashier', 'layout')
  return {
    status: 'success',
    message: receipt ? `Logged ${formatPeso(amount)} as receipt ${receipt}.` : `Logged ${formatPeso(amount)}.`,
  }
}

// Tags one Unpaid charge as Cleared or Waived. Only charges.status is sent. A charge can be Cleared only
// when its payments cover it; Waived needs no payment. When every charge of the student is Cleared or
// Waived, the database clears the Financial clearance item by itself (trigger finance_autoclear).
export async function tagCharge(_prev: TagChargeState, formData: FormData): Promise<TagChargeState> {
  void _prev
  const chargeRaw = String(formData.get('chargeId') ?? '')
  const target = String(formData.get('status') ?? '')
  const chargeId = /^\d+$/.test(chargeRaw) ? Number(chargeRaw) : NaN
  if (!Number.isSafeInteger(chargeId) || (target !== 'Cleared' && target !== 'Waived')) {
    return { status: 'error', message: GENERIC_TAG }
  }

  try {
    const profile = await requireCashier()
    if (!profile) return { status: 'error', message: SESSION_ENDED }
    const supabase = await createClient()

    const { data: charge, error: chargeError } = await supabase
      .from('charges')
      .select('charge_id, amount, status')
      .eq('charge_id', chargeId)
      .maybeSingle()
    if (chargeError) return { status: 'error', message: GENERIC_TAG }
    if (!charge) return { status: 'error', message: 'We could not find that charge.' }
    if (charge.status !== 'Unpaid') {
      return { status: 'error', message: `This charge is already ${charge.status}.` }
    }

    if (target === 'Cleared') {
      const { data: prior, error: priorError } = await supabase
        .from('payments')
        .select('amount_paid')
        .eq('charge_id', chargeId)
      if (priorError) return { status: 'error', message: GENERIC_TAG }
      const balance = round2(Number(charge.amount) - (prior ?? []).reduce((s, p) => s + Number(p.amount_paid), 0))
      if (balance > 0) {
        return {
          status: 'error',
          message: `${formatPeso(balance)} is still unpaid. Log the payment first, or waive the charge.`,
        }
      }
    }

    // .select() returns the updated rows, so a change that RLS silently skipped shows up as no rows.
    const { data: updated, error } = await supabase
      .from('charges')
      .update({ status: target })
      .eq('charge_id', chargeId)
      .eq('status', 'Unpaid')
      .select('charge_id')
    if (error) return { status: 'error', message: chargeTagErrorMessage(error.code, GENERIC_TAG) }
    if (!updated || updated.length === 0) {
      return { status: 'error', message: 'This charge was not changed. It may already be settled. Reload the page.' }
    }
  } catch {
    return { status: 'error', message: GENERIC_TAG }
  }

  revalidatePath('/cashier', 'layout')
  return {
    status: 'success',
    message:
      target === 'Cleared'
        ? 'Charge marked Cleared. The Finance item clears by itself once every charge of the student is settled.'
        : 'Charge waived. The Finance item clears by itself once every charge of the student is settled.',
  }
}
