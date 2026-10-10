<<<<<<< HEAD
import DashboardShell from '@/components/layout/DashboardShell'
import RequestClearanceButton from '@/components/student/RequestClearanceButton'
import { requireRole } from '@/lib/auth/session'
import {
  StatusBadge,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui'
import { MOCK_CURRENT_TERM_ID, MOCK_STUDENT_ID, vClearanceItems } from '@/lib/mock-data'

export default async function StudentClearancePage() {
  const profile = await requireRole('Student')

  const items = vClearanceItems.filter(
    (i) => i.student_id === MOCK_STUDENT_ID && i.term_id === MOCK_CURRENT_TERM_ID
  )

  return (
    <DashboardShell
      profile={profile}
      title="Clearance"
      subtitle="Track each office that must clear you."
    >
      <Table>
        <TableHeader>
          <TableRow className="hover:bg-transparent">
            <TableHead>Department</TableHead>
            <TableHead>Status</TableHead>
            <TableHead className="hidden sm:table-cell">Remarks</TableHead>
            <TableHead className="text-right">Action</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {items.map((item) => (
            <TableRow key={item.clearance_item_id}>
              <TableCell>{item.department_name}</TableCell>
              <TableCell>
                <StatusBadge status={item.status ?? 'Pending'} />
              </TableCell>
              <TableCell className="hidden text-muted sm:table-cell">{item.remarks ?? '-'}</TableCell>
              <TableCell className="text-right">
                {item.status === 'Pending' && (
                  <RequestClearanceButton department={item.department_name ?? 'department'} />
                )}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </DashboardShell>
  )
}
=======
'use client';

import React, { useState } from 'react';
import { Card } from '@/components/ui/Card';
import { StatusBadge } from '@/components/ui/StatusBadge';
import { Button } from '@/components/ui/Button';

export default function StudentClearancePage() {
  const [clearanceOffices, setClearanceOffices] = useState([
    { office: "Cashier's Office", type: "Financial", status: "Cleared", clearedOn: "Oct 3, 2026", remarks: "All charges paid" },
    { office: "CCS Department", type: "Academic", status: "Pending", clearedOn: "—", remarks: "Awaiting department review" },
    { office: "CBA Department", type: "Academic", status: "Cleared", clearedOn: "Oct 2, 2026", remarks: "—" },
    { office: "CAS Department", type: "Academic", status: "Cleared", clearedOn: "Oct 2, 2026", remarks: "—" },
  ]);

  const handleRequestClearance = () => {
    alert('Clearance request submitted successfully!');
  };

  return (
    <div className="min-h-screen bg-[#F8F9FA] p-4 sm:p-6 lg:p-8 font-sans text-gray-800 space-y-6">
      
      {/* Top Header & Request Action Button */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 tracking-tight">My clearance</h1>
          <p className="text-xs text-gray-400 font-medium mt-1">
            1st Sem 2026–2027 · BSCS · one item per office
          </p>
        </div>

        <Button onClick={handleRequestClearance} className="self-start sm:self-auto">
          <svg className="w-3.5 h-3.5 stroke-current" fill="none" viewBox="0 0 24 24" strokeWidth="3" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
          </svg>
          Request clearance
        </Button>
      </div>

      {/* Top Summary Cards Grid */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        
        {/* Offices Total */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Offices</p>
          <p className="text-3xl font-black text-gray-900 tracking-tight">4</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">in total</p>
        </Card>

        {/* Cleared Count */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Cleared</p>
          <p className="text-3xl font-black text-emerald-600 tracking-tight">3</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">of 4 offices</p>
        </Card>

        {/* Pending Count */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Pending</p>
          <p className="text-3xl font-black text-amber-600 tracking-tight">1</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">awaiting review</p>
        </Card>

        {/* Active Holds Count */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Active holds</p>
          <p className="text-3xl font-black text-gray-900 tracking-tight">0</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">no academic holds</p>
        </Card>

      </div>

      {/* Clearance Department Table Card */}
      <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="bg-purple-50/50 text-purple-900 text-[10px] uppercase tracking-wider font-bold border-b border-gray-100">
                <th className="py-3.5 px-6">OFFICE</th>
                <th className="py-3.5 px-6">TYPE</th>
                <th className="py-3.5 px-6">STATUS</th>
                <th className="py-3.5 px-6">CLEARED ON</th>
                <th className="py-3.5 px-6">REMARKS</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-50 text-xs font-medium">
              {clearanceOffices.map((item, index) => (
                <tr key={index} className="hover:bg-gray-50/50 transition-colors">
                  <td className="py-4 px-6 font-bold text-gray-900">{item.office}</td>
                  <td className="py-4 px-6 text-gray-400 font-normal">{item.type}</td>
                  <td className="py-4 px-6">
                    <StatusBadge status={item.status} />
                  </td>
                  <td className="py-4 px-6 text-gray-500 font-normal">{item.clearedOn}</td>
                  <td className="py-4 px-6 text-gray-500 font-normal">{item.remarks}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Note Footer */}
        <div className="bg-white px-6 py-4 border-t border-gray-100 text-[11px] text-gray-400 font-medium">
          Registrar gives final approval once every office has cleared.
        </div>
      </div>

    </div>
  );
}
>>>>>>> ae19a1a (Complete student dashboard pages and components)
