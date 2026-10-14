'use client'

import { useActionState, useState } from 'react'
import { Button, Input, Select } from '@/components/ui'
import { logPayment, type LogPaymentState } from '@/lib/data/cashier-actions'

export type PaymentOption = { chargeId: number; label: string }

const INITIAL: LogPaymentState = { status: 'idle', message: '' }

// Manual payment entry (server action). The date and the receipt number are not asked for: the database
// stamps the time and numbers the receipt when the payment is logged. Field errors sit under their field; the overall result is a live region.
export default function PaymentForm({ options }: { options: PaymentOption[] }) {
  const [chargeId, setChargeId] = useState('')
  const [amount, setAmount] = useState('')

  const [state, formAction, pending] = useActionState(async (prev: LogPaymentState, formData: FormData) => {
    const result = await logPayment(prev, formData)
    if (result.status === 'success') {
      setChargeId('')
      setAmount('')
    }
    return result
  }, INITIAL)
  const errors = state.status === 'error' ? (state.fieldErrors ?? {}) : {}

  return (
    <form
      action={formAction}
      noValidate
      className="grid gap-4 sm:grid-cols-2 lg:grid-cols-[minmax(0,2fr)_minmax(0,1fr)_auto] lg:items-start"
    >
      <div className="sm:col-span-2 lg:col-span-1">
        <Select
          id="pay-charge"
          name="chargeId"
          label="Charge"
          value={chargeId}
          onChange={(e) => setChargeId(e.target.value)}
          error={errors.charge}
        >
          <option value="">Choose a charge</option>
          {options.map((o) => (
            <option key={o.chargeId} value={o.chargeId}>
              {o.label}
            </option>
          ))}
        </Select>
      </div>
      <Input
        id="pay-amount"
        name="amount"
        label="Amount (PHP)"
        type="number"
        inputMode="decimal"
        min="0"
        step="0.01"
        className="text-right tabular-nums"
        value={amount}
        onChange={(e) => setAmount(e.target.value)}
        error={errors.amount}
      />
      <Button type="submit" disabled={pending} className="sm:col-span-2 lg:col-span-1 lg:mt-[26px]">
        {pending ? 'Logging...' : 'Log payment'}
      </Button>
      <p
        role="status"
        aria-live="polite"
        className={
          state.status === 'error'
            ? 'text-sm font-medium text-danger sm:col-span-2 lg:col-span-4'
            : 'text-sm font-medium text-hue-teal-strong sm:col-span-2 lg:col-span-4'
        }
      >
        {state.message}
      </p>
    </form>
  )
}
