import React from 'react';

interface CardProps {
  children: React.ReactNode;
  className?: string;
}

export function Card({ children, className = '' }: CardProps) {
  return (
<<<<<<< HEAD
    <div
      className={cn("rounded-xl border border-border bg-card text-foreground", className)}
      {...props}
    >
=======
    <div className={`bg-white p-5 rounded-2xl border border-gray-100 shadow-sm ${className}`}>
>>>>>>> ae19a1a (Complete student dashboard pages and components)
      {children}
    </div>
  );
}

// Title row used at the top of dashboard cards; `action` is the optional right-hand link or button.
export function CardHeader({
  title,
  action,
  className,
}: {
  title: string;
  action?: React.ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("flex items-center justify-between", className)}>
      <h2 className="text-base font-bold leading-[22px]">{title}</h2>
      {action}
    </div>
  );
}

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
    <Card className={cn("flex flex-col gap-1 p-5", className)}>
      <p className="text-sm font-medium text-muted">{label}</p>
      <p className="text-3xl font-extrabold">{value}</p>
      {hint && <p className="text-sm text-muted">{hint}</p>}
    </Card>
  );
}
