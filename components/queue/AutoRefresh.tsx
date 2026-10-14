'use client'

import { useEffect } from 'react'
import { useRouter } from 'next/navigation'

// Re-reads the page's server data every few seconds while the tab is visible, so the queue stays current
// without realtime. Renders nothing.
export function AutoRefresh({ everySeconds }: { everySeconds: number }) {
  const router = useRouter()

  useEffect(() => {
    const id = setInterval(() => {
      if (document.visibilityState === 'visible') router.refresh()
    }, everySeconds * 1000)
    return () => clearInterval(id)
  }, [router, everySeconds])

  return null
}
