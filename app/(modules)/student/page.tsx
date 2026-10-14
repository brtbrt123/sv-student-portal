import Link from 'next/link'
import DashboardShell from '@/components/layout/DashboardShell'
import PromoCard from '@/components/layout/PromoCard'
import { BarChart, LegendItem, LineChart } from '@/components/charts'
import { ClearanceChain } from '@/components/student/ClearanceChain'
import RequestClearanceButton from '@/components/student/RequestClearanceButton'
import { NextLesson } from '@/components/student/NextLesson'
import {
  Card,
  CardHeader,
  EventCalendar,
  PhotoBanner,
  ScheduleList,
  StatusBadge,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui'
import { requireRole } from '@/lib/auth/session'
import { getStudentClearanceState, toOfficeSteps } from '@/lib/data/clearance'
import { getStudentDashboard } from '@/lib/data/student-dashboard'

const SEE_ALL = 'inline-flex items-center text-sm font-semibold max-lg:min-h-11 text-accent-foreground hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring'
const TH = 'text-sm'
const ON_VEIL_LINK =
  'inline-flex h-10 items-center gap-2 rounded-md bg-on-veil px-4 text-sm font-bold text-(--veil-violet) shadow-elev-sm max-lg:h-11 transition-colors hover:bg-on-veil-muted focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-on-veil'

// Greeting by the hour in the Philippines (the server may run in another time zone).
function greeting() {
  const hour = Number(
    new Intl.DateTimeFormat('en-US', { hour: 'numeric', hourCycle: 'h23', timeZone: 'Asia/Manila' }).format(new Date())
  )
  return hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening'
}

export default async function StudentDashboardPage() {
  const profile = await requireRole('Student')

  const dash = await getStudentDashboard()

  // One GWA series drives both charts. Lower is better: the latest term is highlighted on the bars and
  // the best (lowest) term is pinned on the line.
  const gwaTerms = dash.gwaTerms
  const latest = gwaTerms[gwaTerms.length - 1]
  const bestIndex = gwaTerms.reduce((b, t, i) => (t.gwa < gwaTerms[b].gwa ? i : b), 0)
  const best = gwaTerms[bestIndex]
  const gwaSummary = gwaTerms.map((t) => `${t.full} ${t.gwa.toFixed(2)}`).join(', ')

  // A bar's height is its distance below 3.25, so the best GWA is the tallest bar.
  const bars = gwaTerms.map((t) => ({
    label: t.short,
    value: t.bar,
    display: t.gwa.toFixed(2),
    highlight: t === latest,
  }))

  // Clearance: live data for the signed-in student, the same as the Clearance page.
  const clearanceState = await getStudentClearanceState()

  return (
    <DashboardShell
      profile={profile}
      promo={
        <PromoCard
          value={dash.units}
          label="Units this term"
          note={dash.units > 0 ? 'Keep it up!' : 'Enroll to see your units'}
          image="graduation-cap-books"
        />
      }
    >
      <h1 className="sr-only">Student dashboard</h1>
      {/*
        One grid so the phone reading order is: banner, clearance, next class, then the rest. On xl the
        third column holds the calendar, schedule and next class; the 1fr last row soaks up the left
        column's extra height so the right column never pushes the left one down.
      */}
      <div className="grid gap-4 md:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)] xl:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)_304px] xl:grid-rows-[auto_auto_auto_auto_1fr]">
        <PhotoBanner
          className="md:col-span-2 xl:col-start-1 xl:row-start-1"
          image="study-desk"
          title={`${greeting()}, ${profile.firstName}`}
          subtitle="Here is your clearance, your grades and today's classes."
          aside={
            <Link href="/student/clearance" className={ON_VEIL_LINK}>
              Open clearance
            </Link>
          }
        />

        {clearanceState.kind === 'ready' && clearanceState.clearance ? (
          <ClearanceChain
            className="md:col-start-1 md:row-start-2"
            offices={toOfficeSteps(clearanceState.clearance.items, clearanceState.holds)}
            activeHolds={clearanceState.holds.length}
            approved={clearanceState.clearance.approved}
          />
        ) : (
          <Card elevation="raised" className="flex flex-col gap-4 p-5 md:col-start-1 md:row-start-2">
            <CardHeader
              tinted
              title="Clearance"
              icon="clearance"
              hue="teal"
              action={
                <Link href="/student/clearance" aria-label="See all clearance" className={SEE_ALL}>
                  See all
                </Link>
              }
            />
            {clearanceState.kind === 'error' ? (
              <p role="alert" className="text-sm text-muted">
                We could not load your clearance. Reload the page, and if it keeps happening, come back in a few
                minutes.
              </p>
            ) : clearanceState.kind === 'no-term' ? (
              <p className="text-sm text-muted">No term is open yet. Clearance opens when the Registrar sets one.</p>
            ) : (
              <>
                <p className="text-sm text-muted">
                  You have not requested clearance for {clearanceState.term.semester} {clearanceState.term.schoolYear}{' '}
                  yet.
                </p>
                <RequestClearanceButton />
              </>
            )}
          </Card>
        )}

        <div className="flex flex-col gap-2 md:col-span-2 md:row-start-3 xl:col-span-1 xl:col-start-3 xl:row-start-4 xl:self-start">
          {dash.nextClass ? (
            <NextLesson
              seconds={dash.nextClass.seconds}
              title={dash.nextClass.title}
              code={dash.nextClass.code}
              startsAt={dash.nextClass.startsAt}
            />
          ) : (
            <Card className="p-5">
              <CardHeader title="Next class" />
              <p className="mt-2 text-sm text-muted">
                {dash.enrollmentFailed
                  ? 'We could not load your classes. Reload the page.'
                  : 'Your next class shows here once your enrollment has sections with a schedule.'}
              </p>
            </Card>
          )}
        </div>

        <Card className="flex flex-col gap-3 p-5 md:col-start-2 md:row-start-2">
          <CardHeader tinted title="GWA by term" icon="grades" hue="violet" />
          {latest ? (
            <>
              <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
                <p className="flex flex-col">
                  <span className="text-3xl font-extrabold">{latest.gwa.toFixed(2)}</span>
                  <span className="text-sm text-muted">GWA, {latest.full}</span>
                </p>
                <p className="text-sm font-semibold text-muted">Lower is better</p>
              </div>
              <p className="sr-only">GWA by term, oldest first: {gwaSummary}.</p>
              <div aria-hidden="true" className="mt-auto">
                <BarChart data={bars} max={1.5} hue="violet" ariaLabel="GWA by term" />
              </div>
            </>
          ) : (
            <p className="text-sm text-muted">
              {dash.gradesFailed
                ? 'We could not load your grades. Reload the page.'
                : 'No grades have been posted yet. Your GWA shows here after the Registrar posts them.'}
            </p>
          )}
        </Card>

        <div className="flex min-w-0 flex-col gap-4 md:col-span-2 xl:col-start-1 xl:row-start-3 xl:row-span-3">
          <Card className="flex flex-col gap-2 p-5">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="flex flex-wrap items-baseline gap-x-3">
                <h2 className="text-base font-semibold leading-6">Progress</h2>
                <p className="text-sm font-semibold text-muted">Lower is better</p>
              </div>
              <LegendItem color="var(--hue-violet-strong)">GWA</LegendItem>
            </div>
            {gwaTerms.length >= 2 ? (
              <>
                <p className="sr-only">GWA by term, oldest first: {gwaSummary}. Best: {best.full}, {best.gwa.toFixed(2)}.</p>
                <div aria-hidden="true">
                  <LineChart
                    values={gwaTerms.map((t) => t.gwa)}
                    yTicks={dash.gwaTicks}
                    xLabels={gwaTerms.map((t) => t.short)}
                    hue="violet"
                    mark={{ index: bestIndex, label: `Best ${best.gwa.toFixed(2)}` }}
                    ariaLabel="GWA progress"
                  />
                </div>
                <p className="text-sm text-muted">S1 25 means 1st semester, school year 2025-26.</p>
              </>
            ) : (
              <p className="text-sm text-muted">Your progress line appears after two terms have posted grades.</p>
            )}
          </Card>

          <Card className="flex flex-col overflow-hidden">
            <CardHeader tinted
              title="Current grades"
              icon="grades"
              hue="violet"
              className="px-5 py-4"
              action={
                <Link href="/student/grades" aria-label="See all grades" className={SEE_ALL}>
                  See all
                </Link>
              }
            />
            {dash.gradesLabel && <p className="px-5 pt-3 text-sm text-muted">{dash.gradesLabel}</p>}
            <div className="overflow-x-auto">
              <table className="w-full min-w-[480px] text-left text-sm">
                <TableHeader>
                  <TableRow className="hover:bg-transparent">
                    <TableHead className={`${TH} w-[76px]`}>Code</TableHead>
                    <TableHead className={TH}>Course</TableHead>
                    <TableHead className={`${TH} w-14`}>Units</TableHead>
                    <TableHead className={`${TH} w-[60px]`}>Grade</TableHead>
                    <TableHead className={`${TH} w-28`}>Remarks</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {dash.currentGrades.map((g) => (
                    <TableRow key={g.id}>
                      <TableCell>{g.subjectCode}</TableCell>
                      <TableCell>{g.subjectTitle}</TableCell>
                      <TableCell>{g.units}</TableCell>
                      <TableCell className="font-bold">{g.numericValue !== null ? g.numericValue.toFixed(2) : g.gradeCode}</TableCell>
                      <TableCell>
                        <StatusBadge status={g.result} className="text-sm" />
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </table>
              {dash.currentGrades.length === 0 && (
                <p className="px-5 py-4 text-sm text-muted">
                  {dash.gradesFailed ? 'We could not load your grades. Reload the page.' : 'No grades have been posted yet.'}
                </p>
              )}
            </div>
          </Card>
        </div>

        <div className="flex flex-col gap-4 md:col-span-2 xl:col-span-1 xl:col-start-3 xl:row-start-1 xl:row-span-3 xl:self-start">
          <Card className="p-5">
            <CardHeader title="Event calendar" className="mb-3" />
            <EventCalendar
              year={dash.calendar.year}
              month={dash.calendar.month}
              today={dash.calendar.today}
              events={dash.calendar.events}
            />
          </Card>

          <Card className="flex flex-col gap-3 p-5">
            <CardHeader tinted
              title="My schedule"
              icon="enrollment"
              hue="sky"
              action={
                <Link href="/student/enrollment" aria-label="See all classes" className={SEE_ALL}>
                  See all
                </Link>
              }
            />
            {dash.schedule.length > 0 ? (
              <ScheduleList items={dash.schedule} />
            ) : (
              <p className="text-sm text-muted">
                {dash.enrollmentFailed
                  ? 'We could not load your classes. Reload the page.'
                  : 'No classes yet. They show here once you have an enrollment.'}
              </p>
            )}
          </Card>
        </div>
      </div>
    </DashboardShell>
  )
}
