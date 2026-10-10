import React from 'react';

interface StatusBadgeProps {
  status: 'Cleared' | 'Pending' | 'Passed' | 'Failed' | 'Processing' | 'Released' | string;
  className?: string;
}

export function StatusBadge({ status, className = '' }: StatusBadgeProps) {
  let badgeStyle = 'bg-gray-100 text-gray-700';

  if (status === 'Cleared' || status === 'Passed' || status === 'Released') {
    badgeStyle = 'bg-emerald-100/70 text-emerald-800';
  } else if (status === 'Pending') {
    badgeStyle = 'bg-amber-100/80 text-amber-800';
  } else if (status === 'Processing') {
    badgeStyle = 'bg-purple-100/80 text-purple-800';
  } else if (status === 'Failed') {
    badgeStyle = 'bg-red-100/80 text-red-800';
  }

  return (
    <span className={`inline-flex items-center px-3 py-1 rounded-full text-[11px] font-semibold ${badgeStyle} ${className}`}>
      {status}
    </span>
  );
}