import { createClient } from '@/lib/supabase/server'
import { getCurrentTerm, type CurrentTerm } from '@/lib/data/clearance'
import { formatStudentId } from '@/lib/auth/student-id'

// Server-side reads for the Cashier screens. Every query runs with the signed-in user's own session
// (anon key + auth cookies), so Row Level Security decides what the Cashier can see. No server-only
// key is used. Import this file from Server Components and Server Actions only. Nothing here throws:
// failures come back as { kind: 'error' } so pages show a calm message without internals.

export type ChargeStatus = 'Unpaid' | 'Cleared' | 'Waived'

export type CashierCharge = {
  chargeId: number
  studentId: string
  studentName: string
  studentNo: string
  feeType: string
  amount: number
  dueDate: string | null
  status: ChargeStatus
  paid: number
  /** What the student still owes on this charge. A Waived charge owes nothing. */
  balance: number
  /** Timestamp of the latest payment, or null. */
  lastPaymentAt: string | null
}

export type CashierPayment = {
  paymentId: number
  chargeId: number
  receiptNo: string
  amount: number
  /** Timestamp set by the database when the payment was logged. */
  paidAt: string
  studentName: string
  studentNo: string
  feeType: string
  recordedBy: string
}

export type LedgerTotals = {
  /** Sum of all charges except waived ones. */
  totalCharged: number
  waived: number
  collected: number
  outstanding: number
  unpaidCount: number
}

export type CashierLedger = {
  term: CurrentTerm
  charges: CashierCharge[]
  payments: CashierPayment[]
  totals: LedgerTotals
}

export type LedgerState = { kind: 'ready'; ledger: CashierLedger } | { kind: 'no-term' } | { kind: 'error' }

export type FinanceItem = {
  itemId: number
  studentId: string
  studentName: string
  studentNo: string
  status: 'Cleared' | 'Pending'
  clearedAt: string | null
  remarks: string | null
  /** Reason of an active Financial hold, or null when there is none. */
  holdReason: string | null
  hasHold: boolean
  chargeCount: number
  balance: number
}

export type FinanceClearance = {
  term: CurrentTerm
  items: FinanceItem[]
  cleared: number
  pending: number
  outstanding: number
}

export type FinanceClearanceState = { kind: 'ready'; data: FinanceClearance } | { kind: 'no-term' } | { kind: 'error' }

const round2 = (n: number) => Math.round(n * 100) / 100

function first<T>(value: T | T[] | null | undefined): T | null {
  if (Array.isArray(value)) return value[0] ?? null
  return value ?? null
}

type NameRow = { first_name: string; last_name: string } | null

// "Last, First" like the rest of the portal, or null when the profile is not readable.
function personName(profile: NameRow): string | null {
  return profile ? `${profile.last_name}, ${profile.first_name}` : null
}

const NAME_FALLBACK = 'Student (name not available)'

function toStatus(value: string): ChargeStatus {
  return value === 'Cleared' || value === 'Waived' ? value : 'Unpaid'
}

// Charges of the current term with what was paid on each, plus the term's payment log. Student names
// come from students -> profiles; when RLS hides a name, a neutral label is shown instead.
export async function getCashierLedger(): Promise<LedgerState> {
  try {
    const term = await getCurrentTerm()
    if (!term) return { kind: 'no-term' }
    const supabase = await createClient()

    const [chargesRes, paymentsRes] = await Promise.all([
      supabase
        .from('charges')
        .select(
          'charge_id, student_id, term_id, fee_type_id, amount, due_date, status, fee_types(name), students(student_number, profiles(first_name, last_name))'
        )
        .eq('term_id', term.termId)
        .order('charge_id', { ascending: true }),
      supabase
        .from('payments')
        .select(
          'payment_id, charge_id, amount_paid, paid_at, receipt_number, recorded_by, charges!inner(term_id), profiles(first_name, last_name)'
        )
        .eq('charges.term_id', term.termId)
        .order('paid_at', { ascending: false })
        .order('payment_id', { ascending: false }),
    ])
    if (chargesRes.error || paymentsRes.error) return { kind: 'error' }

    const paidByCharge = new Map<number, number>()
    const lastByCharge = new Map<number, string>()
    for (const p of paymentsRes.data ?? []) {
      paidByCharge.set(p.charge_id, round2((paidByCharge.get(p.charge_id) ?? 0) + Number(p.amount_paid)))
      const seen = lastByCharge.get(p.charge_id)
      if (!seen || p.paid_at > seen) lastByCharge.set(p.charge_id, p.paid_at)
    }

    const charges: CashierCharge[] = (chargesRes.data ?? []).map((c) => {
      const student = first(c.students)
      const status = toStatus(c.status)
      const amount = Number(c.amount)
      const paid = paidByCharge.get(c.charge_id) ?? 0
      return {
        chargeId: c.charge_id,
        studentId: c.student_id,
        studentName: personName(first(student?.profiles) ?? null) ?? NAME_FALLBACK,
        studentNo: student?.student_number ? formatStudentId(student.student_number) : '-',
        feeType: first(c.fee_types)?.name ?? 'Fee',
        amount,
        dueDate: c.due_date,
        status,
        paid,
        balance: status === 'Waived' ? 0 : round2(Math.max(amount - paid, 0)),
        lastPaymentAt: lastByCharge.get(c.charge_id) ?? null,
      }
    })

    const byId = new Map(charges.map((c) => [c.chargeId, c]))
    const payments: CashierPayment[] = (paymentsRes.data ?? []).map((p) => {
      const c = byId.get(p.charge_id)
      return {
        paymentId: p.payment_id,
        chargeId: p.charge_id,
        receiptNo: p.receipt_number,
        amount: Number(p.amount_paid),
        paidAt: p.paid_at,
        studentName: c?.studentName ?? NAME_FALLBACK,
        studentNo: c?.studentNo ?? '-',
        feeType: c?.feeType ?? 'Fee',
        recordedBy: personName(first(p.profiles)) ?? "Cashier's Office",
      }
    })

    const totals: LedgerTotals = {
      totalCharged: round2(charges.filter((c) => c.status !== 'Waived').reduce((s, c) => s + c.amount, 0)),
      waived: round2(charges.filter((c) => c.status === 'Waived').reduce((s, c) => s + c.amount, 0)),
      collected: round2(payments.reduce((s, p) => s + p.amount, 0)),
      outstanding: round2(charges.reduce((s, c) => s + c.balance, 0)),
      unpaidCount: charges.filter((c) => c.status === 'Unpaid').length,
    }

    return { kind: 'ready', ledger: { term, charges, payments, totals } }
  } catch {
    return { kind: 'error' }
  }
}

// The Financial clearance items of the current term (one per student who requested clearance), with
// each student's balance from the ledger and any active Financial hold.
export async function getFinanceClearance(ledger?: CashierLedger): Promise<FinanceClearanceState> {
  try {
    let led = ledger
    if (!led) {
      const state = await getCashierLedger()
      if (state.kind !== 'ready') return state
      led = state.ledger
    }
    const supabase = await createClient()

    const itemsRes = await supabase
      .from('v_clearance_items')
      .select(
        'clearance_item_id, clearance_id, student_id, term_id, department_id, department_name, department_type, cleared_at, cleared_by, remarks, status'
      )
      .eq('term_id', led.term.termId)
      .eq('department_type', 'Financial')
    if (itemsRes.error) return { kind: 'error' }

    const rows = (itemsRes.data ?? []).filter((r) => r.clearance_item_id !== null && r.student_id !== null)
    const studentIds = [...new Set(rows.map((r) => r.student_id as string))]

    const names = new Map<string, { name: string; no: string }>()
    for (const c of led.charges) names.set(c.studentId, { name: c.studentName, no: c.studentNo })

    const missing = studentIds.filter((id) => !names.has(id))
    if (missing.length > 0) {
      const { data } = await supabase
        .from('students')
        .select('student_id, student_number, profiles(first_name, last_name)')
        .in('student_id', missing)
      for (const s of data ?? []) {
        names.set(s.student_id, {
          name: personName(first(s.profiles)) ?? NAME_FALLBACK,
          no: formatStudentId(s.student_number),
        })
      }
    }

    const departmentIds = [...new Set(rows.map((r) => r.department_id).filter((d): d is number => d !== null))]
    const holdByStudent = new Map<string, string>()
    if (studentIds.length > 0 && departmentIds.length > 0) {
      const { data: holds } = await supabase
        .from('v_active_holds')
        .select('hold_id, student_id, department_id, reason')
        .in('student_id', studentIds)
        .in('department_id', departmentIds)
      for (const h of holds ?? []) {
        if (h.student_id) holdByStudent.set(h.student_id, h.reason ?? "Hold placed by the Cashier's Office")
      }
    }

    const items: FinanceItem[] = rows.map((r) => {
      const studentId = r.student_id as string
      const mine = led.charges.filter((c) => c.studentId === studentId)
      const who = names.get(studentId)
      return {
        itemId: r.clearance_item_id as number,
        studentId,
        studentName: who?.name ?? NAME_FALLBACK,
        studentNo: who?.no ?? '-',
        status: r.status === 'Cleared' ? 'Cleared' : 'Pending',
        clearedAt: r.cleared_at,
        remarks: r.remarks,
        holdReason: holdByStudent.get(studentId) ?? null,
        hasHold: holdByStudent.has(studentId),
        chargeCount: mine.length,
        balance: round2(mine.reduce((s, c) => s + c.balance, 0)),
      }
    })
    items.sort(
      (a, b) => Number(a.status === 'Cleared') - Number(b.status === 'Cleared') || a.studentName.localeCompare(b.studentName)
    )

    return {
      kind: 'ready',
      data: {
        term: led.term,
        items,
        cleared: items.filter((i) => i.status === 'Cleared').length,
        pending: items.filter((i) => i.status === 'Pending').length,
        outstanding: round2(items.reduce((s, i) => s + i.balance, 0)),
      },
    }
  } catch {
    return { kind: 'error' }
  }
}
