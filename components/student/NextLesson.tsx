'use client'

import { useEffect, useState } from 'react'

const pad = (n: number) => String(n).padStart(2, '0')

// Dark "Next class" card, raised one level (shadow-elev-md), with a hh:mm:ss countdown. Screen readers
// get one static sentence (the class and its start time); the ticking countdown is hidden from them so
// it is never announced. The first render uses `seconds` exactly as given (same on server and browser)
// and only starts ticking after mount, so there is no hydration mismatch.
export function NextLesson({
  seconds,
  title,
  code,
  startsAt,
  className,
}: {
  seconds: number
  title: string
  code: string
  startsAt: string
  className?: string
}) {
  const [left, setLeft] = useState(seconds)

  useEffect(() => {
    const id = setInterval(() => setLeft((s) => Math.max(s - 1, 0)), 1000)
    return () => clearInterval(id)
  }, [])

  const parts = [Math.floor(left / 3600), Math.floor((left % 3600) / 60), left % 60]

  return (
    <section
      aria-label={`Next class: ${title} at ${startsAt}`}
      className={`flex flex-col gap-2 rounded-lg bg-ink p-5 text-ink-foreground shadow-elev-md ${className ?? ''}`}
    >
      <h2 className="text-sm font-medium">
        Next class at {startsAt}
        <span aria-hidden="true">, starts in</span>
      </h2>
      <p aria-hidden="true" className="flex items-center gap-1.5">
        {parts.map((p, i) => (
          <span key={i} className="flex items-center gap-1.5">
            {i > 0 && <span className="text-base font-bold">:</span>}
            <span className="rounded-md px-2.5 py-2 text-lg font-extrabold tabular-nums">{pad(p)}</span>
          </span>
        ))}
      </p>
      <p className="text-sm font-medium">
        {title} <span className="opacity-80">({code})</span>
      </p>
    </section>
  )
}
