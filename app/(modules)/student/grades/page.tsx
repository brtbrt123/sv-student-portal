<<<<<<< HEAD
import DashboardShell from '@/components/layout/DashboardShell'
import { requireRole } from '@/lib/auth/session'
import {
  Badge,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui'
import { MOCK_CURRENT_TERM_ID, MOCK_STUDENT_ID, vGrades } from '@/lib/mock-data'

export default async function StudentGradesPage() {
  const profile = await requireRole('Student')

  const rows = vGrades.filter(
    (g) => g.student_id === MOCK_STUDENT_ID && g.term_id === MOCK_CURRENT_TERM_ID
  )

  return (
    <DashboardShell profile={profile} title="Grades" subtitle="Your grades per subject.">
      <Table>
        <TableHeader>
          <TableRow className="hover:bg-transparent">
            <TableHead>Subject</TableHead>
            <TableHead>Grade</TableHead>
            <TableHead>Result</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((g) => (
            <TableRow key={g.grade_id}>
              <TableCell>
                <span className="font-semibold">{g.subject_code}</span>
                <span className="block text-muted">{g.subject_title}</span>
              </TableCell>
              <TableCell>{g.grade_code}</TableCell>
              <TableCell>
                <Badge tone={g.is_passing ? 'success' : 'danger'}>
                  {g.is_passing ? 'Passed' : 'Not passed'}
                </Badge>
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

import React from 'react';
import { Card } from '@/components/ui/Card';
import { StatusBadge } from '@/components/ui/StatusBadge';
import { Button } from '@/components/ui/Button';

export default function StudentGradesPage() {
  const gradesData = [
    {
      code: 'CS101',
      course: 'Introduction to Computing',
      units: 3,
      grade: '1.75',
      remarks: 'Passed',
      term: '1st Sem 2026–2027',
    },
    {
      code: 'CS102',
      course: 'Computer Programming 1',
      units: 3,
      grade: '2.00',
      remarks: 'Passed',
      term: '1st Sem 2026–2027',
    },
    {
      code: 'GE101',
      course: 'Understanding the Self',
      units: 3,
      grade: '1.50',
      remarks: 'Passed',
      term: '1st Sem 2026–2027',
    },
  ];

  const handleDownloadReport = () => {
    alert('Downloading official grade report...');
  };

  return (
    <div className="min-h-screen bg-[#F8F9FA] p-4 sm:p-6 lg:p-8 font-sans text-gray-800 space-y-6">
      
      {/* Top Header & Download Action */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 tracking-tight">Grades</h1>
          <p className="text-xs text-gray-400 font-medium mt-1">
            1st Sem 2026–2027 · BSCS · final grades per subject
          </p>
        </div>

        <Button onClick={handleDownloadReport} className="self-start sm:self-auto">
          <svg className="w-3.5 h-3.5 stroke-current" fill="none" viewBox="0 0 24 24" strokeWidth="3" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
          </svg>
          Download grade report
        </Button>
      </div>

      {/* Summary Cards Row */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        
        {/* GWA Card */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">GWA</p>
          <p className="text-3xl font-black text-gray-900 tracking-tight">1.75</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">1st Sem 2026–2027</p>
        </Card>

        {/* Units Earned */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Units earned</p>
          <p className="text-3xl font-black text-gray-900 tracking-tight">9</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">of 9 enrolled</p>
        </Card>

        {/* Passed Count */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Passed</p>
          <p className="text-3xl font-black text-emerald-600 tracking-tight">3</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">subjects</p>
        </Card>

        {/* Failed Count */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Failed</p>
          <p className="text-3xl font-black text-gray-900 tracking-tight">0</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">subjects</p>
        </Card>

      </div>

      {/* Grades Table Card */}
      <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="bg-purple-50/50 text-purple-900 text-[10px] uppercase tracking-wider font-bold border-b border-gray-100">
                <th className="py-3.5 px-6">CODE</th>
                <th className="py-3.5 px-6">COURSE</th>
                <th className="py-3.5 px-6">UNITS</th>
                <th className="py-3.5 px-6">GRADE</th>
                <th className="py-3.5 px-6">REMARKS</th>
                <th className="py-3.5 px-6">TERM</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-50 text-xs font-medium">
              {gradesData.map((item, index) => (
                <tr key={index} className="hover:bg-gray-50/50 transition-colors">
                  <td className="py-4 px-6 font-bold text-gray-900">{item.code}</td>
                  <td className="py-4 px-6 text-gray-500 font-normal">{item.course}</td>
                  <td className="py-4 px-6 text-gray-500 font-normal">{item.units}</td>
                  <td className="py-4 px-6 font-bold text-gray-900">{item.grade}</td>
                  <td className="py-4 px-6">
                    <StatusBadge status={item.remarks} />
                  </td>
                  <td className="py-4 px-6 text-gray-500 font-normal">{item.term}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Table Footer */}
        <div className="bg-white px-6 py-4 border-t border-gray-100 text-[11px] text-gray-400 font-medium">
          Showing 3 of 3 subjects
        </div>
      </div>

    </div>
  );
}
>>>>>>> ae19a1a (Complete student dashboard pages and components)
