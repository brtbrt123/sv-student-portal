'use client';

import React, { useState } from 'react';

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
    <div className="min-h-screen bg-[#F8F9FA] p-4 sm:p-6 lg:p-8 font-sans text-gray-800">
      
      {/* Top Header & Request Action (REQ-STU-06) */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 mb-6">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 tracking-tight">My clearance</h1>
          <p className="text-xs text-gray-400 font-medium mt-1">
            1st Sem 2026–2027 · BSCS · one item per office
          </p>
        </div>

        <button 
          onClick={handleRequestClearance}
          className="bg-gray-900 hover:bg-black text-white text-xs font-semibold px-4 py-2.5 rounded-xl shadow-sm flex items-center gap-2 self-start sm:self-auto transition-colors cursor-pointer"
        >
          <svg className="w-3.5 h-3.5 stroke-current" fill="none" viewBox="0 0 24 24" strokeWidth="3" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
          </svg>
          Request clearance
        </button>
      </div>

      {/* Top Summary Cards Grid */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
        
        {/* Offices Total */}
        <div className="bg-white p-5 rounded-2xl border border-gray-100 shadow-sm flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Offices</p>
          <p className="text-3xl font-black text-gray-900 tracking-tight">4</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">in total</p>
        </div>

        {/* Cleared Count */}
        <div className="bg-white p-5 rounded-2xl border border-gray-100 shadow-sm flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Cleared</p>
          <p className="text-3xl font-black text-emerald-600 tracking-tight">3</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">of 4 offices</p>
        </div>

        {/* Pending Count */}
        <div className="bg-white p-5 rounded-2xl border border-gray-100 shadow-sm flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Pending</p>
          <p className="text-3xl font-black text-amber-600 tracking-tight">1</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">awaiting review</p>
        </div>

        {/* Active Holds Count */}
        <div className="bg-white p-5 rounded-2xl border border-gray-100 shadow-sm flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Active holds</p>
          <p className="text-3xl font-black text-gray-900 tracking-tight">0</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">no academic holds</p>
        </div>

      </div>

      {/* Clearance Department Table Card (REQ-STU-03) */}
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
                    <span
                      className={`inline-flex items-center px-3 py-1 rounded-full text-[11px] font-semibold ${
                        item.status === 'Cleared'
                          ? 'bg-emerald-100/70 text-emerald-800'
                          : 'bg-amber-100/80 text-amber-800'
                      }`}
                    >
                      {item.status}
                    </span>
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