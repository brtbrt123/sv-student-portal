<<<<<<< HEAD
import DashboardShell from '@/components/layout/DashboardShell'
import { requireRole } from '@/lib/auth/session'
import { Badge, Card, CardHeader, StatCard, StatusBadge } from '@/components/ui'
import {
  MOCK_CURRENT_TERM_ID,
  MOCK_STUDENT_ID,
  departments,
  enrollments,
  terms,
  vActiveHolds,
  vClearanceItems,
} from '@/lib/mock-data'

export default async function StudentDashboardPage() {
  const profile = await requireRole('Student')
=======
import React from 'react';

export default function StudentGradesPage() {
  const academicTerms = [
    {
      term: "Term 1 (2026-2027)",
      gwa: "1.75",
      status: "Completed",
      subjects: [
        { code: "CS101", description: "Introduction to Computing", units: 3, grade: "1.75", remarks: "Passed" },
        { code: "CS102", description: "Computer Programming 1", units: 3, grade: "2.00", remarks: "Passed" },
        { code: "GE101", description: "Understanding the Self", units: 3, grade: "1.50", remarks: "Passed" },
        { code: "MATH101", description: "Calculus 1", units: 3, grade: "1.75", remarks: "Passed" },
      ],
    },
  ];
>>>>>>> ae19a1a (Complete student dashboard pages and components)

  const term = terms.find((t) => t.term_id === MOCK_CURRENT_TERM_ID)
  const enrollment = enrollments.find(
    (e) => e.student_id === MOCK_STUDENT_ID && e.term_id === MOCK_CURRENT_TERM_ID
  )
  const items = vClearanceItems.filter(
    (i) => i.student_id === MOCK_STUDENT_ID && i.term_id === MOCK_CURRENT_TERM_ID
  )
  const cleared = items.filter((i) => i.status === 'Cleared').length
  const holds = vActiveHolds.filter((h) => h.student_id === MOCK_STUDENT_ID)

  return (
<<<<<<< HEAD
    <DashboardShell
      profile={profile}
      title="Student Dashboard"
      subtitle="Your enrollment, clearance and holds at a glance."
    >
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
        <Card className="flex flex-col gap-2 p-5">
          <p className="text-sm font-medium text-muted">Enrollment status</p>
          <div>
            <StatusBadge status={enrollment?.status ?? 'Pending'} />
          </div>
          <p className="text-sm text-muted">
            {term ? `${term.semester}, ${term.school_year}` : 'Current term'}
          </p>
        </Card>
        <StatCard
          label="Clearance summary"
          value={`${cleared} / ${items.length}`}
          hint={`${cleared} cleared, ${items.length - cleared} pending`}
        />
        <StatCard
          label="Active holds"
          value={holds.length}
          hint={holds.length ? 'Resolve holds to proceed' : 'No active holds'}
          className="sm:col-span-2 xl:col-span-1"
        />
      </div>

      <Card className="mt-6 p-5">
        <CardHeader title="Active holds" />
        {holds.length === 0 ? (
          <p className="mt-3 text-sm text-muted">You have no active holds.</p>
        ) : (
          <ul className="mt-3 divide-y divide-border-subtle">
            {holds.map((hold) => (
              <li
                key={hold.hold_id}
                className="flex flex-col gap-1 py-3 sm:flex-row sm:items-center sm:justify-between"
              >
                <div>
                  <p className="text-sm font-semibold">{hold.reason}</p>
                  <p className="text-sm text-muted">
                    {departments.find((d) => d.department_id === hold.department_id)?.name}
                  </p>
                </div>
                <Badge tone="danger" className="self-start">On hold</Badge>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </DashboardShell>
  )
}
=======
    <div className="p-6 bg-gray-50/50 min-h-full space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Academic Grades</h1>
          <p className="text-xs text-gray-500">View your term grades, subject units, and pass/not passed status.</p>
        </div>
        <div className="bg-white px-4 py-2 rounded-xl border border-gray-100 shadow-sm flex items-center gap-3 self-start sm:self-auto">
          <span className="text-xs text-gray-500 font-medium">Cumulative GWA:</span>
          <span className="px-2.5 py-0.5 bg-emerald-50 text-emerald-700 text-xs font-bold rounded-md">1.75</span>
        </div>
      </div>

      {/* REQ-STU-02: Grades Table */}
      {academicTerms.map((termData, index) => (
        <div key={index} className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
          <div className="bg-purple-50/50 px-5 py-3 border-b border-gray-100 flex justify-between items-center">
            <div>
              <h3 className="font-semibold text-gray-900 text-sm">{termData.term}</h3>
              <p className="text-[11px] text-gray-500">Status: <span className="font-medium text-emerald-600">{termData.status}</span></p>
            </div>
            <div className="text-right">
              <span className="text-[10px] text-gray-400 uppercase block font-semibold">Term GWA</span>
              <span className="font-bold text-gray-900 text-base">{termData.gwa}</span>
            </div>
          </div>

          <div className="overflow-x-auto">
            <table className="w-full text-left border-collapse text-xs">
              <thead>
                <tr className="text-purple-900 uppercase text-[10px] tracking-wider bg-gray-50/50 border-b border-gray-100">
                  <th className="py-3 px-5 font-semibold">Subject Code</th>
                  <th className="py-3 px-5 font-semibold">Course Description</th>
                  <th className="py-3 px-5 font-semibold">Units</th>
                  <th className="py-3 px-5 font-semibold">Grade</th>
                  <th className="py-3 px-5 font-semibold">Remarks</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-100">
                {termData.subjects.map((subject, subIndex) => (
                  <tr key={subIndex} className="hover:bg-gray-50/50">
                    <td className="py-3.5 px-5 font-semibold text-gray-900">{subject.code}</td>
                    <td className="py-3.5 px-5 text-gray-600">{subject.description}</td>
                    <td className="py-3.5 px-5 text-gray-500">{subject.units}</td>
                    <td className="py-3.5 px-5 font-bold text-gray-900">{subject.grade}</td>
                    <td className="py-3.5 px-5">
                      <span className="px-2.5 py-0.5 rounded-full text-[10px] font-bold bg-emerald-50 text-emerald-700">
                        {subject.remarks}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      ))}
    </div>
  );
}
>>>>>>> ae19a1a (Complete student dashboard pages and components)
