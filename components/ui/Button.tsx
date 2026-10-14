import { cn } from "@/lib/utils";

// primary = the one main action on a screen (charcoal pill; marigold in dark). accent = a soft secondary that still
// belongs to the brand. outline = the usual secondary. ghost = quiet tertiary. danger = destructive.
const variants = {
  primary: "bg-primary text-primary-foreground hover:bg-primary-hover",
  accent: "bg-accent text-accent-foreground hover:bg-lilac-soft",
  outline: "glass border border-field-border/60 bg-card text-foreground hover:border-field-border hover:bg-card-raised",
  ghost: "text-muted hover:bg-hover-tint hover:text-foreground",
  danger: "border border-danger/30 bg-danger-soft text-danger hover:border-danger/60 hover:bg-danger-soft/70",
} as const;

export type ButtonVariant = keyof typeof variants;

// 36px high on desktop, 44px below lg (touch). Pill corners, a slight press on click.
export function Button({
  className,
  variant = "primary",
  type = "button",
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { variant?: ButtonVariant }) {
  return (
    <button
      type={type}
      className={cn(
        "inline-flex h-9 items-center justify-center gap-2 rounded-full px-4 text-sm font-semibold whitespace-nowrap transition-[color,background-color,border-color,transform] duration-150 select-none max-lg:h-11 max-lg:px-5",
        "motion-safe:active:scale-[0.98]",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring",
        "disabled:pointer-events-none disabled:opacity-50",
        variants[variant],
        className
      )}
      {...props}
    />
  );
}
