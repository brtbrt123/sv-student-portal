'use client';

import React, { useState } from 'react';
import { Card } from '@/components/ui/Card';
import { StatusBadge } from '@/components/ui/StatusBadge';
import { Button } from '@/components/ui/Button';

export default function StudentDocumentRequestsPage() {
  const [requests, setRequests] = useState([
    {
      document: 'Transcript of Records',
      purpose: 'Job application',
      requestedOn: 'Oct 1, 2026',
      status: 'Processing',
      processedOn: 'Oct 2, 2026',
    },
    {
      document: 'Certificate of Grades',
      purpose: 'Scholarship',
      requestedOn: 'Oct 5, 2026',
      status: 'Pending',
      processedOn: '—',
    },
    {
      document: 'Good Moral Certificate',
      purpose: 'Transfer',
      requestedOn: 'Sep 24, 2026',
      status: 'Released',
      processedOn: 'Sep 26, 2026',
    },
  ]);

  const handleNewRequest = () => {
    alert('New document request modal opened!');
  };

  return (
    <div className="min-h-screen bg-[#F8F9FA] p-4 sm:p-6 lg:p-8 font-sans text-gray-800 space-y-6">
      
      {/* Top Header & New Request Button */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 tracking-tight">Document requests</h1>
          <p className="text-xs text-gray-400 font-medium mt-1">
            Request records from the Registrar and track their status
          </p>
        </div>

        <Button onClick={handleNewRequest} className="self-start sm:self-auto">
          <svg className="w-3.5 h-3.5 stroke-current" fill="none" viewBox="0 0 24 24" strokeWidth="3" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
          </svg>
          New request
        </Button>
      </div>

      {/* Summary Cards Grid */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        
        {/* Total Requests */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Requests</p>
          <p className="text-3xl font-black text-gray-900 tracking-tight">3</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">all time</p>
        </Card>

        {/* Pending */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Pending</p>
          <p className="text-3xl font-black text-amber-600 tracking-tight">1</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">not yet processed</p>
        </Card>

        {/* Processing */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Processing</p>
          <p className="text-3xl font-black text-purple-600 tracking-tight">1</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">with the Registrar</p>
        </Card>

        {/* Released */}
        <Card className="flex flex-col justify-between">
          <p className="text-xs text-gray-400 font-medium mb-1">Released</p>
          <p className="text-3xl font-black text-emerald-600 tracking-tight">1</p>
          <p className="text-[11px] text-gray-400 font-medium mt-1">collected</p>
        </Card>

      </div>

      {/* Document Requests Table Card */}
      <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="bg-purple-50/50 text-purple-900 text-[10px] uppercase tracking-wider font-bold border-b border-gray-100">
                <th className="py-3.5 px-6">DOCUMENT</th>
                <th className="py-3.5 px-6">PURPOSE</th>
                <th className="py-3.5 px-6">REQUESTED ON</th>
                <th className="py-3.5 px-6">STATUS</th>
                <th className="py-3.5 px-6">PROCESSED ON</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-50 text-xs font-medium">
              {requests.map((item, index) => (
                <tr key={index} className="hover:bg-gray-50/50 transition-colors">
                  <td className="py-4 px-6 font-bold text-gray-900">{item.document}</td>
                  <td className="py-4 px-6 text-gray-500 font-normal">{item.purpose}</td>
                  <td className="py-4 px-6 text-gray-500 font-normal">{item.requestedOn}</td>
                  <td className="py-4 px-6">
                    <StatusBadge status={item.status} />
                  </td>
                  <td className="py-4 px-6 text-gray-500 font-normal">{item.processedOn}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Table Footer */}
        <div className="bg-white px-6 py-4 border-t border-gray-100 text-[11px] text-gray-400 font-medium">
          Students can only file requests. The Registrar updates the status.
        </div>
      </div>

    </div>
  );
}