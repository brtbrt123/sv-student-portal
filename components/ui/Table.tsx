import { cn } from "@/lib/utils";

// A hairline-ruled sheet. The header has no fill (a solid card background so it can be made sticky),
// 12px medium muted labels in sentence case; rows are separated by a subtle rule and tint on hover.
export function Table({ className, ...props }: React.HTMLAttributes<HTMLTableElement>) {
  return (
    <div className="glass w-full overflow-x-auto rounded-lg border border-edge bg-card shadow-elev-sm">
      <table className={cn("w-full text-left text-sm tabular-nums text-foreground", className)} {...props} />
    </div>
  );
}

export function TableHeader({ className, ...props }: React.HTMLAttributes<HTMLTableSectionElement>) {
  return <thead className={cn("glass border-b border-border bg-card", className)} {...props} />;
}

export function TableBody(props: React.HTMLAttributes<HTMLTableSectionElement>) {
  return <tbody {...props} />;
}

export function TableRow({ className, ...props }: React.HTMLAttributes<HTMLTableRowElement>) {
  return (
    <tr
      className={cn(
        "border-b border-border-subtle transition-colors last:border-b-0 [tbody_&]:hover:bg-hover-tint",
        className
      )}
      {...props}
    />
  );
}

export function TableHead({ className, ...props }: React.ThHTMLAttributes<HTMLTableCellElement>) {
  return (
    <th
      className={cn("h-11 px-4 py-2 align-middle text-xs font-medium whitespace-nowrap text-muted", className)}
      {...props}
    />
  );
}

export function TableCell({ className, ...props }: React.TdHTMLAttributes<HTMLTableCellElement>) {
  return <td className={cn("h-12 px-4 py-2.5 align-middle", className)} {...props} />;
}

// Row for a table with nothing to show. `colSpan` is the number of columns.
export function EmptyRow({ colSpan, children }: { colSpan: number; children: React.ReactNode }) {
  return (
    <tr>
      <td colSpan={colSpan} className="px-4 py-10 text-center text-sm text-muted">
        {children}
      </td>
    </tr>
  );
}
