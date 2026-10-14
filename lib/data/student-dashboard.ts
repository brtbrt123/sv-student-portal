import { createClient } from '@/lib/supabase/server'
import { getStudentEnrollmentState, type ChosenSection } from '@/lib/data/enrollment'
import { getStudentGradesState, type StudentGrade } from '@/lib/data/grades'
import {
  gwaBarValue,
  gwaYTicks,
  pickNextClass,
  shortTermLabel,
  type NowParts,
} from '@/lib/data/student-dashboard-map'

// Live numbers for the Student dashboard. Everything runs with the signed-in student's own session
// (Row Level Security does the isolation). Never throws: a failed block comes back as null.

const TONES = ['violet', 'sky', 'teal'] as const
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

export type DashboardScheduleItem = { time: string; title: string; code: string; tone: (typeof TONES)[number] }
export type DashboardGwaTerm = { short: string; full: string; gwa: number; bar: number }

export type StudentDashboardData = {
  termLabel: string | null
  /** Units of the current term's enrollment (0 when there is none or it was rejected). */
  units: number
  schedule: DashboardScheduleItem[]
  nextClass: { code: string; title: string; startsAt: string; seconds: number } | null
  /** Oldest first. */
  gwaTerms: DashboardGwaTerm[]
  gwaTicks: number[]
  gradesLabel: string | null
  currentGrades: StudentGrade[]
  calendar: {
    year: number
    month: number
    today: string
    events: { id: string; title: string; tone: 'sky' | 'rose'; dates: string[] }[]
  }
  gradesFailed: boolean
  enrollmentFailed: boolean
}

// Date and clock in the Philippines, whatever time zone the server runs in.
function manilaNow(): { iso: string; year: number; month: number; parts: NowParts } {
  const f = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Asia/Manila',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    weekday: 'short',
    hour: 'numeric',
    minute: 'numeric',
    second: 'numeric',
    hourCycle: 'h23',
  })
  const p = Object.fromEntries(f.formatToParts(new Date()).map((x) => [x.type, x.value]))
  return {
    iso: `${p.year}-${p.month}-${p.day}`,
    year: Number(p.year),
    month: Number(p.month) - 1,
    parts: {
      weekday: WEEKDAYS.indexOf(p.weekday),
      minutes: Number(p.hour) * 60 + Number(p.minute),
      seconds: Number(p.second),
    },
  }
}

function scheduleOf(chosen: ChosenSection[]): DashboardScheduleItem[] {
  return chosen.map((c, i) => ({
    time: c.schedule ?? 'Schedule to be announced',
    title: c.subjectTitle,
    code: c.subjectCode,
    tone: TONES[i % TONES.length],
  }))
}

export async function getStudentDashboard(): Promise<StudentDashboardData> {
  const now = manilaNow()
  const [enr, grades] = await Promise.all([getStudentEnrollmentState(), getStudentGradesState()])

  const enrolled = enr.kind === 'ready' && enr.enrollment && enr.enrollment.status !== 'Rejected'
  const chosen = enr.kind === 'ready' && enrolled ? enr.chosen : []

  // Term dates for the calendar.
  const events: StudentDashboardData['calendar']['events'] = []
  if (enr.kind === 'ready') {
    try {
      const supabase = await createClient()
      const { data } = await supabase
        .from('terms')
        .select('start_date, end_date')
        .eq('term_id', enr.term.termId)
        .maybeSingle()
      if (data) {
        events.push({ id: 'start', title: `${enr.term.semester} starts`, tone: 'sky', dates: [data.start_date.slice(0, 10)] })
        events.push({ id: 'end', title: `${enr.term.semester} ends`, tone: 'rose', dates: [data.end_date.slice(0, 10)] })
      }
    } catch {
      // The calendar just shows no term dates.
    }
  }

  const gradeTerms = grades.kind === 'ready' ? grades.terms : []
  const withGwa = gradeTerms.filter((t) => t.gwa !== null).reverse()
  const latest = gradeTerms[0]
  const semesterOf = (label: string) => {
    const m = label.match(/^(.*?)\s+(\d{4}\S*)$/)
    return m ? { semester: m[1], schoolYear: m[2] } : { semester: label, schoolYear: '' }
  }

  return {
    termLabel: enr.kind === 'ready' ? `${enr.term.semester} ${enr.term.schoolYear}` : null,
    units: chosen.reduce((s, c) => s + c.units, 0),
    schedule: scheduleOf(chosen),
    nextClass: pickNextClass(
      chosen.map((c) => ({ code: c.subjectCode, title: c.subjectTitle, schedule: c.schedule })),
      now.parts
    ),
    gwaTerms: withGwa.map((t) => {
      const { semester, schoolYear } = semesterOf(t.label)
      return {
        short: shortTermLabel(semester, schoolYear),
        full: t.label,
        gwa: t.gwa as number,
        bar: gwaBarValue(t.gwa as number),
      }
    }),
    gwaTicks: gwaYTicks(withGwa.map((t) => t.gwa as number)),
    gradesLabel: latest ? latest.label : null,
    currentGrades: latest ? latest.grades : [],
    calendar: { year: now.year, month: now.month, today: now.iso, events },
    gradesFailed: grades.kind === 'error',
    enrollmentFailed: enr.kind === 'error',
  }
}
