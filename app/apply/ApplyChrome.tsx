import Link from 'next/link'
import { ThemeToggle } from '@/components/ui/ThemeToggle'

// Shared top bar and footer of the public enrollment pages (/apply and /apply/enroll). Plain server
// components: no data, no sign-in.
// showEnroll is false on the form page, where "Enroll now" would point at the page you are already on.
export function ApplyHeader({ showEnroll = true }: { showEnroll?: boolean }) {
  return (
    <>
      <div className="flex items-center justify-center bg-[#303030] px-4 py-2 text-center text-xs font-medium text-white sm:text-sm">
        <p>
          Enrollment for <span className="font-bold text-gold">A.Y. 2026&ndash;2027</span> is now open
        </p>
      </div>
      <header className="sticky top-0 z-30 flex w-full items-center justify-between gap-3 border-b border-black/[0.05] bg-white/80 px-5 py-3 backdrop-blur-md after:pointer-events-none after:absolute after:inset-x-0 after:-bottom-px after:h-[3px] after:bg-gradient-to-r after:from-gold after:via-gold/50 after:to-transparent dark:border-white/[0.08] dark:bg-[#121214]/80 sm:px-8 lg:px-10">
        <Link href="/apply" className="min-w-0 rounded-full focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring">
          <span className="block text-2xl font-extrabold leading-[0.95] tracking-tight text-foreground sm:text-4xl sm:leading-normal">
            <span className="block text-gold [-webkit-text-stroke:1.5px_#303030] [paint-order:stroke_fill] sm:inline dark:[-webkit-text-stroke:0]">Cabuyao</span>{' '}
            <span className="block sm:inline">University</span>
          </span>
        </Link>
        <div className="flex shrink-0 items-center gap-2">
          <ThemeToggle />
          <Link
            href="/login"
            className="inline-flex items-center rounded-full bg-[#303030] px-5 py-2 text-sm font-semibold text-white transition hover:bg-black focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring max-lg:min-h-11 dark:bg-white/10 dark:hover:bg-white/20"
          >
            Portal
          </Link>
          {showEnroll && (
            <Link
              href="/apply/enroll"
              className="hidden items-center rounded-full bg-gold px-5 py-2 text-sm font-bold text-[#18181b] shadow-elev-xs transition hover:-translate-y-0.5 hover:brightness-95 hover:shadow-elev-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring motion-reduce:hover:translate-y-0 max-lg:min-h-11 sm:inline-flex"
            >
              Enroll now
            </Link>
          )}
        </div>
      </header>
    </>
  )
}

export function ApplyFooter() {
  return (
    <footer className="mx-auto w-full max-w-6xl px-5 py-6 text-xs text-muted sm:px-8">
      <p>© 2026 Cabuyao University</p>
    </footer>
  )
}
