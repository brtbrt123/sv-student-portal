import type { Metadata } from 'next'
import Image from 'next/image'
import Link from 'next/link'
import { ApplyFooter, ApplyHeader } from '../ApplyChrome'
import { ApplyForm } from '../ApplyForm'
import { listPrograms } from '../programs'

export const metadata: Metadata = {
  title: 'Apply for enrollment | Cabuyao University',
  description: 'Apply to enroll at Cabuyao University.',
}

// The enrollment form for new applicants. No sign-in; the page only talks to the database through two rpcs
// that anon may call (list_programs, submit_application). Large screens: the photo and the "what happens
// next" card on the left, the form on the right. Phones: photo, form, then the card.
export default async function EnrollPage() {
  const programs = await listPrograms()

  return (
    <div className="min-h-dvh">
      <ApplyHeader showEnroll={false} />
      <main className="mx-auto grid w-full max-w-6xl items-start gap-6 px-5 pb-10 pt-2 sm:px-8 lg:grid-cols-[0.9fr_1.1fr] lg:gap-x-10 lg:pt-6">
        <div className="relative aspect-[16/9] w-full overflow-hidden rounded-3xl border border-edge shadow-elev-md sm:aspect-[2/1] lg:col-start-1 lg:row-start-1 lg:aspect-[4/3]">
          <Image
            src="/photos/campus-yellow-building.jpg"
            alt="A school building with a wide green field in front"
            fill
            priority
            sizes="(min-width: 1024px) 480px, 100vw"
            className="object-cover object-[50%_40%]"
          />
          <div aria-hidden="true" className="absolute inset-x-0 bottom-0 h-3/5 bg-gradient-to-t from-black/60 to-transparent" />
          <div className="absolute inset-x-0 bottom-0 p-5 text-white sm:p-6">
            <p className="text-2xl font-semibold leading-tight tracking-[-0.02em] sm:text-3xl">Start your enrollment</p>
            <p className="mt-1 text-sm text-white/90">For A.Y. 2026-2027</p>
          </div>
        </div>

        <div className="glass rounded-3xl border border-edge bg-card p-6 shadow-elev-sm sm:p-8 lg:col-start-2 lg:row-span-2 lg:row-start-1">
          <h1 className="text-2xl font-semibold tracking-[-0.02em] sm:text-3xl">Apply for enrollment</h1>
          <p className="mt-1.5 text-base text-muted">For new students. It takes about a minute.</p>
          <div className="mt-7">
            <ApplyForm programs={programs} />
          </div>
        </div>

        <section
          aria-labelledby="next-title"
          className="glass rounded-3xl border border-warm-edge bg-warm-glass p-6 text-sm leading-6 sm:p-7 lg:col-start-1 lg:row-start-2"
        >
          <h2 id="next-title" className="text-lg font-semibold">
            What happens next
          </h2>
          <ol className="mt-4 flex flex-col gap-4">
            {[
              ['You apply', 'Fill in the form. It takes about a minute.'],
              ['The Registrar reviews', 'Your application is checked by the Registrar’s Office.'],
              ['You get an email', 'If it is accepted, we email your student ID and a link to set your password. Check your spam folder too.'],
              ['Finish at the school', 'Sign in with your student ID, open Queue, and show your QR code at the Registrar’s window. Bring a valid ID.'],
            ].map(([title, text], i) => (
              <li key={title} className="flex items-start gap-3">
                <span aria-hidden="true" className="mt-0.5 grid size-7 shrink-0 place-items-center rounded-full bg-gold text-sm font-extrabold text-[#18181b]">
                  {i + 1}
                </span>
                <span>
                  <span className="block text-base font-semibold text-foreground">{title}</span>
                  <span className="text-muted">{text}</span>
                </span>
              </li>
            ))}
          </ol>

          <h2 id="your-data" className="mt-7 scroll-mt-24 text-lg font-semibold">
            Your data
          </h2>
          <p className="mt-1.5 text-muted">
            We collect only what we need: your name and email to review your application and contact you, your mobile number
            (optional) in case the Registrar needs to reach you, and the program you choose. It is used for enrollment only, as the Data
            Privacy Act requires.
          </p>
          <p className="mt-5">
            <Link href="/apply" className="font-medium text-foreground underline underline-offset-4">
              Back to enrollment
            </Link>
          </p>
        </section>
      </main>
      <ApplyFooter />
    </div>
  )
}
