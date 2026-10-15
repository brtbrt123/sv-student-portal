import Image from 'next/image'
import { cn } from '@/lib/utils'

// Photo panel for the sign-in page (from lg up): one photo inside a large circle that bleeds off the
// outer edge, a thin ring just outside it, and a lavender tint that is deepest at the bottom where the
// text sits. Both variants use the same warm charcoal veil, so staff matches the student side. The photo is the PM's (public/photos); the copy is plain product fact, no claims.
// `side` is the side of the page the panel sits on: the circle bleeds off that edge and the text moves
// to the inner side. The sign-in page puts the student panel on the right and the staff panel on the left.
export function LoginShowcase({
  variant = 'student',
  side = 'right',
  className,
}: {
  variant?: 'student' | 'staff'
  side?: 'left' | 'right'
  className?: string
}) {
  const staff = variant === 'staff'
  const onLeft = side === 'left'
  return (
    <aside aria-label={staff ? "About the staff portal" : "About the portal"} className={cn('relative hidden overflow-hidden lg:block', className)}>
      <div className={cn('absolute top-1/2 aspect-square w-[min(56vw,96vh)] -translate-y-1/2', onLeft ? 'right-[6%]' : 'left-[6%]')}>
        <div aria-hidden="true" className="absolute -inset-5 rounded-full border border-hue-violet-solid/30" />
        <div className="absolute inset-0 overflow-hidden rounded-full bg-ink">
          <Image
            src={staff ? "/photos/staff-office.jpg" : "/photos/lecture-hall.jpg"}
            alt={staff ? "An office where staff work at their desks" : "Students in a lecture hall with laptops"}
            fill
            priority
            sizes="50vw"
            className="object-cover"
          />
          <div
            aria-hidden="true"
            className="absolute inset-0"
            style={{
              background:
                'linear-gradient(to top, color-mix(in srgb, var(--veil-violet) 94%, transparent), color-mix(in srgb, var(--veil-violet) 62%, transparent) 55%, color-mix(in srgb, var(--veil-violet) 38%, transparent))',
            }}
          />
          <div className={cn('absolute inset-x-0 bottom-0 pb-[16%] text-white', onLeft ? 'pl-[17%] pr-[23%]' : 'pl-[16%] pr-[26%]')}>
            <p className="text-balance text-3xl font-semibold leading-tight tracking-[-0.01em] [text-shadow:0_1px_14px_rgb(0_0_0/0.35)]">
              {staff ? 'Review, approve and record in one place.' : 'Welcome! Manage your enrollment, grades, and clearance all in one place.'}
            </p>
            <p className="mt-3 max-w-[38ch] text-sm leading-6 text-white/90 [text-shadow:0_1px_10px_rgb(0_0_0/0.35)]">
              {staff
                ? 'For the Registrar, Cashier, Department and Admin offices. Every change is recorded in the audit log.'
                : 'Sign in to see where your requests are and what comes next.'}
            </p>
          </div>
        </div>
      </div>
    </aside>
  )
}
