import { cn } from "@/lib/utils";
import React from 'react';

export interface CardProps extends React.HTMLAttributes<HTMLDivElement> {
  children: React.ReactNode;
  className?: string;
}

export function Card({ children, className, ...props }: CardProps) {
  return (
    <div
      className={cn(
        "rounded-2xl border border-gray-100 bg-white p-5 text-gray-800 shadow-sm transition-all",
        className
      )}
      {...props}
    >
      {children}
    </div>
  );
}

export interface CardHeaderProps extends React.HTMLAttributes<HTMLDivElement> {
  title: string;
  action?: React.ReactNode;
  className?: string;
}

export function CardHeader({
  title,
  action,
  className,
  ...props
}: CardHeaderProps) {
  return (
    <div 
      className={cn("flex items-center justify-between mb-3", className)}
      {...props}
    >
      <h2 className="text-sm font-bold text-gray-900 tracking-tight leading-snug">{title}</h2>
      {action && <div className="flex items-center gap-2">{action}</div>}
    </div>
  );
}

export interface StatCardProps extends React.HTMLAttributes<HTMLDivElement> {
  label: string;
  value: React.ReactNode;
  hint?: React.ReactNode;
  valueClassName?: string;
  className?: string;
}

export function StatCard({
  label,
  value,
  hint,
  valueClassName,
  className,
  ...props
}: StatCardProps) {
  return (
    <Card className={cn("flex flex-col justify-between", className)} {...props}>
      <p className="text-xs font-medium text-gray-400 mb-1">{label}</p>
      <div className={cn("text-3xl font-black text-gray-900 tracking-tight", valueClassName)}>
        {value}
      </div>
      {hint && <p className="text-[11px] font-medium text-gray-400 mt-1">{hint}</p>}
    </Card>
  );
}