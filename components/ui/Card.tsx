import { Icon, type IconKey } from "@/components/layout/Icon";
import { cn } from "@/lib/utils";
import { HUE_SOFT, HUE_TEXT } from "./hue";
import type { Hue } from "./hue";

// A sheet: white (lighter ink in dark) with one hairline. "flat" = hairline only, "base" = hairline plus
// a 1px contact shadow, "raised" = a touch more. In dark mode depth is the lighter surface + hairline.
const ELEVATION = {
  flat: "shadow-none",
  base: "shadow-elev-sm",
  raised: "shadow-elev-md",
} as const;

// `interactive`: only for a card that is itself one link or button. The hairline darkens on hover and
// the focus ring shows when anything inside has keyboard focus. No movement.
const INTERACTIVE =
  "transition-colors hover:border-field-border hover:bg-card-raised " +
  "has-focus-visible:outline-2 has-focus-visible:outline-offset-2 has-focus-visible:outline-ring";

// tone: "glass" = the standard frosted surface, "warm" = soft marigold-tinted glass for one highlighted card,
// "charcoal" = the dark featured card (white text). Layout and content are never affected by the tone.
const TONE = {
  glass: "bg-card",
  warm: "border-warm-edge bg-warm-glass",
  charcoal: "border-white/10 bg-ink text-ink-foreground",
} as const;

export function Card({
  className,
  children,
  elevation = "base",
  interactive = false,
  tone = "glass",
  ...props
}: React.HTMLAttributes<HTMLDivElement> & {
  elevation?: keyof typeof ELEVATION;
  interactive?: boolean;
  tone?: keyof typeof TONE;
}) {
  return (
    <div
      className={cn(
        "glass rounded-lg border border-edge text-foreground",
        TONE[tone],
        ELEVATION[elevation],
        interactive && INTERACTIVE,
        className
      )}
      {...props}
    >
      {children}
    </div>
  );
}

// Title row at the top of a section or sheet; `action` is the optional right-hand link or button.
// `icon` renders a quiet muted glyph before the title (no tinted chip). `hue` is accepted for
// compatibility and no longer coloured: colour is kept for meaning, not topics.
export function CardHeader({
  title,
  action,
  icon,
  hue = "violet",
  tinted = false,
  className,
}: {
  title: string;
  action?: React.ReactNode;
  icon?: IconKey;
  hue?: Hue;
  /** Draw the icon in a small chip tinted with the card's topic hue (used on the student dashboard). */
  tinted?: boolean;
  className?: string;
}) {
  return (
    <div className={cn("flex min-h-6 items-center justify-between gap-3", className)}>
      <div className="flex min-w-0 items-center gap-2">
        {icon &&
          (tinted ? (
            <span
              aria-hidden="true"
              className={cn("flex size-6 shrink-0 items-center justify-center rounded-md", HUE_SOFT[hue], HUE_TEXT[hue])}
            >
              <Icon name={icon} className="size-3.5" />
            </span>
          ) : (
            <Icon name={icon} className="size-4 text-muted" />
          ))}
        <h2 className="truncate text-base font-semibold">{title}</h2>
      </div>
      {action}
    </div>
  );
}

// Figure with a label: 13px muted label, 28px semibold tabular number, optional hint.
export function StatCard({
  label,
  value,
  hint,
  className,
}: {
  label: string;
  value: React.ReactNode;
  hint?: string;
  className?: string;
}) {
  return (
    <Card elevation="flat" className={cn("flex flex-col gap-1 p-4 lg:p-5", className)}>
      <p className="text-[13px] leading-5 font-medium text-muted">{label}</p>
      <p className="text-3xl font-semibold tabular-nums">{value}</p>
      {hint && <p className="text-[13px] leading-5 text-muted">{hint}</p>}
    </Card>
  );
}

// Placeholder block while content loads. Size it with className (h-4 w-32 ...). Decorative only:
// put the loading text (aria-busy / sr-only) on the region that is loading.
export function Skeleton({ className }: { className?: string }) {
  return (
    <span
      aria-hidden="true"
      className={cn("block animate-pulse rounded-md bg-hover-tint motion-reduce:animate-none", className)}
    />
  );
}

// Quiet empty state for a section with nothing to show yet: what is missing, then what happens next.
export function EmptyState({
  title,
  children,
  action,
  className,
}: {
  title: string;
  children?: React.ReactNode;
  action?: React.ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex flex-col items-start gap-1 rounded-lg border border-dashed border-field-border/40 px-5 py-8",
        className
      )}
    >
      <p className="text-sm font-semibold">{title}</p>
      {children && <div className="max-w-[60ch] text-sm text-muted">{children}</div>}
      {action && <div className="mt-2">{action}</div>}
    </div>
  );
}
