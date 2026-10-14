import type { IconName } from '@/lib/nav'
import { cn } from '@/lib/utils'

// Icons drawn by Figma are SVG files in public/figma/icons. They keep their own fixed colors, so
// they are shown as a CSS mask filled with currentColor: the icon follows the text color of its
// parent (and therefore light/dark) without editing the SVG.
const ASSETS = {
  dashboard: 'nav-dashboard',
  enrollment: 'nav-enrollment',
  grades: 'nav-grades',
  encode: 'nav-grades-bars',
  clearance: 'nav-clearance',
  documents: 'nav-documents',
  notifications: 'nav-notifications',
  settings: 'nav-settings',
  menu: 'topbar-menu',
  search: 'topbar-search',
  bell: 'topbar-bell',
  more: 'more-vertical',
  'chevron-down': 'chevron-down',
  check: 'office-check',
  clock: 'office-clock',
} as const

// Hand-drawn fallbacks for roles whose Figma icons are not exported yet (24px grid, currentColor).
const PATHS = {
  charges: <><rect x="3" y="6" width="18" height="12" rx="2" /><circle cx="12" cy="12" r="2.5" /></>,
  payments: <><rect x="2" y="5" width="20" height="14" rx="2" /><path d="M2 10h20M6 15h4" /></>,
  holds: <><circle cx="12" cy="12" r="9" /><path d="M12 7v5M12 16h.01" /></>,
  users: <><circle cx="9" cy="8" r="3.5" /><path d="M2 20c0-3.5 3-6 7-6s7 2.5 7 6M17 5a3 3 0 0 1 0 6M22 20c0-2.5-1.5-4.5-4-5.3" /></>,
  setup: <><circle cx="12" cy="12" r="3" /><path d="M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2" /></>,
  queue: <><circle cx="5" cy="6" r="1.5" /><path d="M10 6h11" /><circle cx="5" cy="12" r="1.5" /><path d="M10 12h11" /><circle cx="5" cy="18" r="1.5" /><path d="M10 18h11" /></>,
  audit: <><path d="M9 3h6l1 2h3v16H5V5h3z" /><path d="M9 12h6M9 16h6" /></>,
  logout: <><path d="M9 4H5a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h4" /><path d="m16 8 4 4-4 4M20 12H9" /></>,
} as const

export type IconKey = keyof typeof ASSETS | keyof typeof PATHS

export function Icon({ name, className = 'size-[18px]' }: { name: IconKey | IconName; className?: string }) {
  if (name in ASSETS) {
    const url = `url(/figma/icons/${ASSETS[name as keyof typeof ASSETS]}.svg)`
    return (
      <span
        aria-hidden="true"
        className={cn('inline-block shrink-0 bg-current', className)}
        style={{
          maskImage: url,
          WebkitMaskImage: url,
          maskRepeat: 'no-repeat',
          WebkitMaskRepeat: 'no-repeat',
          maskPosition: 'center',
          WebkitMaskPosition: 'center',
          maskSize: 'contain',
          WebkitMaskSize: 'contain',
        }}
      />
    )
  }
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={cn('shrink-0', className)}
    >
      {PATHS[name as keyof typeof PATHS]}
    </svg>
  )
}
