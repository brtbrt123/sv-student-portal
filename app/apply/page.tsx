import type { Metadata } from 'next'
import Image from 'next/image'
import Link from 'next/link'
import { CuMark } from '@/components/auth/CabuyaoLogo'
import { ApplyFooter, ApplyHeader } from './ApplyChrome'

export const metadata: Metadata = {
  title: 'Enrollment | Cabuyao University',
  description: 'Enroll at Cabuyao University for A.Y. 2026-2027.',
}

const CTA =
  'inline-flex h-12 items-center justify-center rounded-full px-8 text-base font-semibold transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring max-lg:h-12'

const STEPS = [
  { title: 'Fill in the form', text: 'Your name, email and the program you want. It takes about a minute.' },
  { title: 'The Registrar reviews it', text: 'A Registrar checks your application.' },
  {
    title: 'Get your student ID',
    text: 'If it is accepted, we email your student ID and a link to set your password. Then you sign in with your student ID.',
  },
] as const

// Public enrollment landing page for new applicants. No sign-in and no data: the form lives at /apply/enroll.
// After the form is sent, /apply?notice=submitted shows the confirmation in place of the landing.
export default async function ApplyPage({ searchParams }: { searchParams: Promise<{ notice?: string }> }) {
  const { notice } = await searchParams

  return (
    <div className="min-h-dvh">
      <ApplyHeader />
      <main>{notice === 'submitted' ? <Received /> : <Landing />}</main>
      <ApplyFooter />
    </div>
  )
}

function Landing() {
  return (
    <>
      <section aria-labelledby="hero-title" className="mb-12 grid min-h-[85vh] grid-cols-1 items-center overflow-hidden bg-[#FDFDFD] dark:bg-[#121214] lg:mb-20 lg:min-h-[90vh] lg:grid-cols-12">
        <div className="relative h-full min-h-[500px] w-full overflow-hidden [-webkit-mask-image:linear-gradient(to_bottom,rgba(0,0,0,1)_70%,rgba(0,0,0,0)_100%)] [mask-image:linear-gradient(to_bottom,rgba(0,0,0,1)_70%,rgba(0,0,0,0)_100%)] lg:col-span-7 lg:min-h-[750px] lg:[-webkit-mask-image:linear-gradient(to_right,rgba(0,0,0,1)_60%,rgba(0,0,0,0)_100%)] lg:[mask-image:linear-gradient(to_right,rgba(0,0,0,1)_60%,rgba(0,0,0,0)_100%)]">
          <Image
            src="/photos/campus-yellow-building.jpg"
            alt="A yellow school building with a wide green field in front"
            fill
            priority
            sizes="(min-width: 1024px) 58vw, 100vw"
            className="h-full w-full object-cover object-[center_45%] [filter:sepia(0.22)_saturate(0.92)_contrast(1.03)]"
          />
          <div aria-hidden="true" className="absolute inset-0 bg-gradient-to-br from-[#ffd85e]/35 to-[#ffd85e]/10 mix-blend-soft-light" />
        </div>

        <div className="flex flex-col items-center px-5 py-12 text-center sm:px-8 lg:col-span-5 lg:py-16 lg:pl-2 lg:pr-12">
          <div className="mb-6 flex flex-col items-center justify-center gap-2">
            <CuMark className="w-32" />
            <span className="text-xl font-bold text-foreground">Cabuyao University</span>
          </div>
          <h1
            id="hero-title"
            className="flex flex-col items-center text-[clamp(2.5rem,4.8vw,4rem)] font-extrabold uppercase leading-none tracking-[-0.02em] text-foreground"
          >
            Enrollment
            <span className="mt-3 block whitespace-nowrap rounded-sm bg-primary px-5 py-2.5 text-[0.82em] text-primary-foreground shadow-elev-sm">
              Now ongoing!
            </span>
          </h1>
          <p className="mt-5 text-lg font-bold uppercase tracking-[0.12em] text-foreground">For A.Y. 2026&ndash;2027</p>
          <Link
            href="/apply/enroll"
            className={`${CTA} mt-8 h-14 bg-gold px-12 text-lg font-bold uppercase tracking-wide text-[#18181b] shadow-elev-md hover:-translate-y-0.5 hover:brightness-95 hover:shadow-elev-lg motion-reduce:hover:translate-y-0`}
          >
            Enroll now
          </Link>
        </div>
      </section>

      <section id="how-it-works" aria-labelledby="steps-title" className="mx-auto w-full max-w-6xl scroll-mt-24 px-5 pb-12 sm:px-8">
        <div className="glass rounded-3xl border border-edge bg-card p-6 shadow-elev-sm sm:p-8">
          <h2 id="steps-title" className="text-xl font-semibold">
            How enrollment works
          </h2>
          <ol className="mt-6 grid gap-6 md:grid-cols-3 md:gap-8">
            {STEPS.map((step, i) => (
              <li key={step.title} className="flex gap-4">
                <span
                  aria-hidden="true"
                  className="flex size-9 shrink-0 items-center justify-center rounded-full bg-primary text-sm font-semibold text-primary-foreground"
                >
                  {i + 1}
                </span>
                <div>
                  <h3 className="text-base font-semibold">{step.title}</h3>
                  <p className="mt-1 text-sm leading-6 text-muted">{step.text}</p>
                </div>
              </li>
            ))}
          </ol>
          <p id="your-data" className="mt-8 max-w-[75ch] scroll-mt-24 border-t border-border pt-5 text-sm leading-6 text-muted">
            <span className="font-semibold text-foreground">Your data.</span> We collect only what we need: your name and email to review
            your application and contact you, your mobile number (optional) in case the Registrar needs to reach you, and the program you
            choose. It is used for enrollment only, as the Data Privacy Act requires.
          </p>
        </div>
      </section>
    </>
  )
}

function Received() {
  return (
    <section aria-labelledby="done-title" className="mx-auto flex w-full max-w-xl flex-col px-5 pb-16 pt-10 sm:px-8">
      <div className="glass rounded-3xl border border-warm-edge bg-warm-glass p-8 text-center shadow-elev-md">
        <span aria-hidden="true" className="mx-auto flex size-14 items-center justify-center rounded-full bg-gold text-[#18181b]">
          <svg viewBox="0 0 24 24" fill="none" className="size-7">
            <path d="m5 12.5 4.5 4.5L19 7.5" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </span>
        <h1 id="done-title" className="mt-5 text-2xl font-semibold">
          Application received
        </h1>
        <p className="mt-3 text-sm leading-6 text-muted">
          Thank you. The Registrar will review your application. If it is accepted, you will receive an email with your student ID and a
          link to set your password. Please check your inbox, and your spam folder, in the coming days.
        </p>
        <div className="mt-6 flex flex-wrap justify-center gap-3">
          <Link href="/login" className={`${CTA} bg-primary text-primary-foreground hover:bg-primary-hover`}>
            Go to sign in
          </Link>
          <Link
            href="/apply"
            className={`${CTA} glass border border-field-border/60 bg-card text-foreground hover:border-field-border hover:bg-card-raised`}
          >
            Back to enrollment
          </Link>
        </div>
      </div>
    </section>
  )
}
