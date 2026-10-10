'use client';

import React, { useState } from 'react';
import { Card } from '@/components/ui/Card';
import { StatusBadge } from '@/components/ui/StatusBadge';
import { Button } from '@/components/ui/Button';

export default function RegistrarEncodeGradesPage() {
  const [students, setStudents] = useState([
    { no: "2026-0001", name: "Reyes, Ana", grade: "1.75", description: "Good", result: "Passed", status: "Saved", hasError: false, isUnsaved: false },
    { no: "2026-0002", name: "Santos, Ben", grade: "2.25", description: "Very Satisfactory", result: "Passed", status: "Saved", hasError: false, isUnsaved: false },
    { no: "2026-0003", name: "Mendoza, Carla", grade: "1.50", description: "Very Good", result: "Passed", status: "Unsaved", hasError: false, isUnsaved: true },
    { no: "2026-0004", name: "Garcia, Miguel R.", grade: "—", description: "—", result: "—", status: "Not encoded", hasError: false, isUnsaved: false },
    { no: "2026-0005", name: "Mendoza, Sofia T.", grade: "9.00", description: "—", result: "—", status: "Invalid grade", hasError: true, isUnsaved: false },
    { no: "2026-0006", name: "Ramos, Daniel P.", grade: "1.25", description: "Superior", result: "Passed", status: "Saved", hasError: false, isUnsaved: false },
    { no: "2026-0007", name: "Torres, Bianca K.", grade: "5.00", description: "Failed", result: "Failed", status: "Saved", hasError: false, isUnsaved: false },
    { no: "2026-0008", name: "Villanueva, Carlo J.", grade: "2.00", description: "Meritorious", result: "Passed", status: "Unsaved", hasError: false, isUnsaved: true },
  ]);

  const handleGradeChange = (index: number, newGrade: string) => {
    const updated = [...students];
    updated[index].grade = newGrade;
    updated[index].status = "Unsaved";
    updated[index].isUnsaved = true;
    setStudents(updated);
  };

  return (
    <div className="min-h-screen bg-[#F8F9FA] p-4 sm:p-6 lg:p-8 font-sans text-gray-800 space-y-6">
      
      {/* Top Header & Actions */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 tracking-tight">Encode grades</h1>
          <p className="text-xs text-gray-400 font-medium mt-1">
            CS101 · Introduction to Computing · 1st Sem 2026–2027
          </p>
        </div>

        <div className="flex items-center gap-3 self-start sm:self-auto">
          <Button variant="secondary" onClick={() => alert('CSV file importer opened')}>
            <svg className="w-3.5 h-3.5 text-gray-500" fill="none" viewBox="0 0 24 24" strokeWidth="2" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5m-13.5-9L12 3m0 0l4.5 4.5M12 3v13.5" />
            </svg>
            Import CSV
          </Button>

          <Button variant="primary" onClick={() => alert('Grades submitted successfully!')}>
            <svg className="w-3.5 h-3.5 stroke-current" fill="none" viewBox="0 0 24 24" strokeWidth="3" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
            </svg>
            Submit grades
          </Button>
        </div>
      </div>

      {/* Metric Summary Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        
        {/* Total Students */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Students</p>
          <p className="text-3xl font-black text-gray-900 tracking-tight">42</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">in this section</p>
        </Card>

        {/* Encoded Count */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Encoded</p>
          <p className="text-3xl font-black text-gray-900 tracking-tight">33</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">of 42</p>
        </Card>

        {/* Unsaved Count */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Unsaved</p>
          <p className="text-3xl font-black text-amber-600 tracking-tight">2</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">changes pending</p>
        </Card>

        {/* Error Count */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Errors</p>
          <p className="text-3xl font-black text-red-600 tracking-tight">1</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">needs attention</p>
        </Card>

      </div>

      {/* Filter and Search Bar Card */}
      <Card className="!p-4 flex flex-wrap items-center gap-4">
        <div className="flex-1 min-w-[200px]">
          <label className="block text-[10px] font-semibold text-gray-400 mb-1 uppercase tracking-wider">Course / Section</label>
          <select className="w-full bg-white border border-gray-200 rounded-xl px-3 py-2 text-xs font-semibold text-gray-800 outline-none cursor-pointer">
            <option>CS101 · Intro to Computing</option>
          </select>
        </div>

        <div className="w-full sm:w-36">
          <label className="block text-[10px] font-semibold text-gray-400 mb-1 uppercase tracking-wider">School year</label>
          <select className="w-full bg-white border border-gray-200 rounded-xl px-3 py-2 text-xs font-semibold text-gray-800 outline-none cursor-pointer">
            <option>2026–2027</option>
          </select>
        </div>

        <div className="w-full sm:w-40">
          <label className="block text-[10px] font-semibold text-gray-400 mb-1 uppercase tracking-wider">Semester</label>
          <select className="w-full bg-white border border-gray-200 rounded-xl px-3 py-2 text-xs font-semibold text-gray-800 outline-none cursor-pointer">
            <option>1st Semester</option>
          </select>
        </div>

        <div className="flex-1 min-w-[220px]">
          <label className="block text-[10px] font-semibold text-gray-400 mb-1 uppercase tracking-wider">Search student</label>
          <div className="relative">
            <span className="absolute inset-y-0 left-0 pl-3 flex items-center text-gray-400 text-xs">🔍</span>
            <input 
              type="text" 
              placeholder="Name or student number" 
              className="w-full bg-white border border-gray-200 rounded-xl pl-9 pr-3 py-2 text-xs text-gray-800 outline-none placeholder-gray-400"
            />
          </div>
        </div>
      </Card>

      {/* Student Grades List Table Card */}
      <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="bg-purple-50/50 text-purple-900 text-[10px] uppercase tracking-wider font-bold border-b border-gray-100">
                <th className="py-3.5 px-4 w-10 text-center">
                  <input type="checkbox" className="rounded border-gray-300 text-purple-600 focus:ring-purple-500 cursor-pointer" />
                </th>
                <th className="py-3.5 px-4">STUDENT NO.</th>
                <th className="py-3.5 px-4">STUDENT NAME</th>
                <th className="py-3.5 px-4">GRADE</th>
                <th className="py-3.5 px-4">DESCRIPTION</th>
                <th className="py-3.5 px-4">RESULT</th>
                <th className="py-3.5 px-4">STATUS</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-50 text-xs font-medium">
              {students.map((item, index) => (
                <tr 
                  key={index} 
                  className={`transition-colors ${
                    item.hasError ? 'bg-red-50/30' : 
                    item.isUnsaved ? 'bg-amber-50/30' : 'hover:bg-gray-50/50'
                  }`}
                >
                  <td className="py-3.5 px-4 text-center">
                    <input type="checkbox" className="rounded border-gray-300 text-purple-600 focus:ring-purple-500 cursor-pointer" />
                  </td>
                  <td className="py-3.5 px-4 text-gray-400 font-mono text-[11px]">{item.no}</td>
                  <td className="py-3.5 px-4 font-bold text-gray-900">{item.name}</td>
                  <td className="py-3.5 px-4">
                    <input 
                      type="text" 
                      value={item.grade}
                      onChange={(e) => handleGradeChange(index, e.target.value)}
                      className={`w-16 px-2.5 py-1.5 border rounded-lg text-center font-bold text-xs outline-none transition-all ${
                        item.hasError 
                          ? 'border-red-500 text-red-600 bg-white ring-2 ring-red-100' 
                          : 'border-gray-200 text-gray-900 bg-white focus:border-purple-500'
                      }`}
                    />
                  </td>
                  <td className="py-3.5 px-4 text-gray-600 font-normal">{item.description}</td>
                  <td className="py-3.5 px-4 font-bold text-gray-900">{item.result}</td>
                  <td className="py-3.5 px-4">
                    <StatusBadge status={item.status} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Pagination Footer */}
        <div className="bg-white px-6 py-4 border-t border-gray-100 flex flex-col sm:flex-row sm:items-center justify-between gap-3 text-xs text-gray-400 font-medium">
          <span>Showing 1–8 of 42 students</span>
          <div className="flex items-center gap-1 self-center sm:self-auto">
            <button className="px-2.5 py-1.5 rounded-lg border border-gray-200 text-gray-400 hover:bg-gray-50 cursor-pointer">‹</button>
            <button className="px-3 py-1.5 rounded-lg bg-gray-900 text-white font-bold">1</button>
            <button className="px-3 py-1.5 rounded-lg border border-gray-200 text-gray-700 hover:bg-gray-50 cursor-pointer">2</button>
            <button className="px-3 py-1.5 rounded-lg border border-gray-200 text-gray-700 hover:bg-gray-50 cursor-pointer">3</button>
            <button className="px-2.5 py-1.5 rounded-lg border border-gray-200 text-gray-700 hover:bg-gray-50 cursor-pointer">›</button>
          </div>
        </div>
      </div>

    </div>
  );
}