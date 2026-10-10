import React from 'react';
import { Card } from '@/components/ui/Card';
import { StatusBadge } from '@/components/ui/StatusBadge';

export default function StudentDashboardPage() {
  return (
    <div className="min-h-screen bg-[#F8F9FA] p-4 sm:p-6 lg:p-8 font-sans text-gray-800">
      
      {/* Outer Dashboard Responsive Grid */}
      <div className="grid grid-cols-1 lg:grid-cols-4 gap-6">
        
        {/* MAIN DASHBOARD CONTENT (3 Columns on Large Screens) */}
        <div className="lg:col-span-3 space-y-6">
          
          {/* Top 3 Metric Cards */}
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-6">
            
            {/* Clearance Summary Doughnut */}
            <Card className="flex flex-col justify-between">
              <div className="flex justify-between items-center mb-2">
                <h3 className="font-bold text-gray-900 text-sm tracking-tight">Clearance</h3>
                <button className="text-gray-400 hover:text-gray-600 text-xs font-bold">•••</button>
              </div>
              
              <div className="flex flex-col items-center my-3">
                <div className="relative w-28 h-28 rounded-full border-[10px] border-purple-100 border-t-purple-500 border-r-purple-500 flex items-center justify-center shadow-inner">
                  <span className="text-2xl font-black text-gray-900">75%</span>
                </div>
              </div>

              <div className="flex justify-center items-center gap-4 text-[11px] text-gray-500 font-medium">
                <span className="flex items-center gap-1.5">
                  <span className="w-2 h-2 rounded-full bg-purple-500"></span> Cleared
                </span>
                <span className="flex items-center gap-1.5">
                  <span className="w-2 h-2 rounded-full bg-purple-200"></span> Pending
                </span>
              </div>
            </Card>

            {/* GWA by Term Bar Chart */}
            <Card className="flex flex-col justify-between">
              <div className="flex justify-between items-center mb-2">
                <h3 className="font-bold text-gray-900 text-sm tracking-tight">GWA by term</h3>
                <button className="text-gray-400 hover:text-gray-600 text-xs font-bold">•••</button>
              </div>
              
              <div className="flex items-end justify-between h-28 px-1 my-2">
                {[
                  { term: 'T1', height: 'h-12', active: false },
                  { term: 'T2', height: 'h-16', active: false },
                  { term: 'T3', height: 'h-14', active: false },
                  { term: 'T4', height: 'h-20', active: false },
                  { term: 'T5', height: 'h-24', active: true, gwa: '1.75' },
                  { term: 'T6', height: 'h-18', active: false },
                ].map((item) => (
                  <div key={item.term} className="flex flex-col items-center gap-1.5">
                    {item.active && (
                      <span className="text-[10px] bg-black text-white font-bold px-1.5 py-0.5 rounded shadow">
                        {item.gwa}
                      </span>
                    )}
                    <div className={`w-3.5 rounded-t-md transition-all ${item.active ? 'bg-emerald-500' : 'bg-emerald-200'} ${item.height}`}></div>
                    <span className="text-[11px] font-medium text-gray-400">{item.term}</span>
                  </div>
                ))}
              </div>
            </Card>

            {/* Pending Items & Active Holds */}
            <Card className="flex flex-col justify-between">
              <div className="flex justify-between items-center mb-2">
                <h3 className="font-bold text-gray-900 text-sm tracking-tight">Pending items</h3>
                <button className="text-gray-400 hover:text-gray-600 text-xs font-bold">•••</button>
              </div>
              
              <div className="space-y-4 my-2">
                <div>
                  <div className="flex justify-between items-center text-xs font-bold text-gray-800">
                    <span>CCS Department</span>
                    <span className="text-amber-600 font-medium">Pending</span>
                  </div>
                  <p className="text-[11px] text-gray-400 mt-0.5">Awaiting department review</p>
                </div>
                <div className="pt-2 border-t border-gray-50">
                  <div className="flex justify-between items-center text-xs font-bold text-gray-800">
                    <span>Active holds</span>
                    <span className="text-gray-700 font-medium">0</span>
                  </div>
                  <p className="text-[11px] text-gray-400 mt-0.5">No academic holds</p>
                </div>
              </div>
            </Card>

          </div>

          {/* Progress Chart Card */}
          <Card>
            <div className="flex justify-between items-center mb-4">
              <h3 className="font-bold text-gray-900 text-sm tracking-tight">Progress</h3>
              <div className="flex items-center gap-3 text-xs">
                <span className="flex items-center gap-1.5 font-semibold text-gray-700">
                  <span className="w-2 h-2 rounded-full bg-amber-500"></span> GWA
                </span>
                <select className="bg-purple-50 border border-purple-100 text-purple-900 font-semibold px-2.5 py-1 rounded-lg outline-none text-[11px] cursor-pointer">
                  <option>All terms</option>
                </select>
              </div>
            </div>

            {/* Responsive Line Chart SVG */}
            <div className="relative w-full h-36">
              <svg className="w-full h-full overflow-visible" viewBox="0 0 600 120" preserveAspectRatio="none">
                <polyline
                  fill="none"
                  stroke="#111827"
                  strokeWidth="2.5"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  points="0,80 50,100 120,50 200,90 280,70 340,90 420,20 480,100 530,70 600,68"
                />
              </svg>
            </div>

            <div className="flex justify-between text-xs text-gray-400 font-medium border-t border-gray-100 pt-2 mt-2">
              <span>T1</span><span>T2</span><span>T3</span><span>T4</span><span>T5</span><span>T6</span>
            </div>
          </Card>

          {/* Bottom Grid: Current Grades & Clearance Offices */}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            
            {/* Current Grades Table */}
            <Card>
              <div className="flex justify-between items-center mb-4">
                <h3 className="font-bold text-gray-900 text-sm tracking-tight">Current grades</h3>
                <a href="/student/grades" className="text-xs text-purple-600 font-bold hover:underline">See all</a>
              </div>
              <div className="overflow-x-auto">
                <table className="w-full text-left text-xs border-collapse">
                  <thead>
                    <tr className="bg-purple-50/70 text-purple-900 text-[10px] uppercase tracking-wider font-bold">
                      <th className="py-2.5 px-3 rounded-l-lg">CODE</th>
                      <th className="py-2.5 px-3">COURSE</th>
                      <th className="py-2.5 px-3">UNITS</th>
                      <th className="py-2.5 px-3">GRADE</th>
                      <th className="py-2.5 px-3 rounded-r-lg">REMARKS</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-50">
                    {[
                      { code: 'CS101', course: 'Introduction to Computing', units: 3, grade: '1.75', remarks: 'Passed' },
                      { code: 'CS102', course: 'Computer Programming 1', units: 3, grade: '2.00', remarks: 'Passed' },
                      { code: 'GE101', course: 'Understanding the Self', units: 3, grade: '1.50', remarks: 'Passed' },
                    ].map((row, idx) => (
                      <tr key={idx} className="hover:bg-gray-50/50">
                        <td className="py-3 px-3 font-semibold text-gray-900">{row.code}</td>
                        <td className="py-3 px-3 text-gray-600 font-medium">{row.course}</td>
                        <td className="py-3 px-3 text-gray-500">{row.units}</td>
                        <td className="py-3 px-3 font-bold text-gray-900">{row.grade}</td>
                        <td className="py-3 px-3"><StatusBadge status={row.remarks} /></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </Card>

            {/* Clearance Offices List */}
            <Card>
              <div className="flex justify-between items-center mb-4">
                <h3 className="font-bold text-gray-900 text-sm tracking-tight">Clearance offices</h3>
                <a href="/student/clearance" className="text-xs text-purple-600 font-bold hover:underline">See all</a>
              </div>
              <div className="space-y-3.5 text-xs">
                {[
                  { name: "Cashier's Office", status: "Cleared", subtitle: "Completed" },
                  { name: "CBA Department", status: "Cleared", subtitle: "Completed" },
                  { name: "CAS Department", status: "Cleared", subtitle: "Completed" },
                  { name: "CCS Department", status: "Pending", subtitle: "Awaiting review" },
                ].map((office, idx) => (
                  <div key={idx} className="flex items-center justify-between">
                    <div className="flex items-center gap-2.5">
                      <div className={`w-6 h-6 rounded-full flex items-center justify-center text-xs font-bold ${office.status === 'Cleared' ? 'bg-emerald-100 text-emerald-700' : 'bg-amber-100 text-amber-700'}`}>
                        {office.status === 'Cleared' ? '✓' : '🕒'}
                      </div>
                      <div>
                        <p className="font-bold text-gray-900">{office.name}</p>
                        <p className="text-[11px] text-gray-400">{office.subtitle}</p>
                      </div>
                    </div>
                    <StatusBadge status={office.status} />
                  </div>
                ))}
              </div>
            </Card>

          </div>

        </div>

        {/* RIGHT SIDEBAR PANEL */}
        <div className="space-y-6">
          
          {/* Event Calendar Widget */}
          <Card>
            <div className="flex justify-between items-center mb-3">
              <h3 className="font-bold text-gray-900 text-sm tracking-tight">Event calendar</h3>
            </div>
            
            <div className="flex items-center justify-between text-xs font-bold text-gray-800 mb-3 px-1">
              <button className="w-6 h-6 rounded-full bg-gray-100 hover:bg-gray-200 flex items-center justify-center text-gray-600">‹</button>
              <span>October 2026</span>
              <button className="w-6 h-6 rounded-full bg-gray-100 hover:bg-gray-200 flex items-center justify-center text-gray-600">›</button>
            </div>

            <div className="grid grid-cols-7 text-center text-[11px] font-bold text-red-400 mb-2">
              <span>S</span><span className="text-gray-400">M</span><span className="text-gray-400">T</span><span className="text-gray-400">W</span><span className="text-gray-400">T</span><span className="text-gray-400">F</span><span className="text-gray-400">S</span>
            </div>

            <div className="grid grid-cols-7 text-center text-xs gap-y-1.5 font-medium text-gray-700">
              <div></div><div></div><div></div><div></div>
              {[1, 2, 3].map((d) => <span key={d}>{d}</span>)}
              {Array.from({ length: 28 }, (_, i) => i + 4).map((day) => (
                <span 
                  key={day} 
                  className={`py-1 rounded-full text-xs transition-all ${
                    day === 5 ? 'bg-gray-900 text-white font-bold shadow' : 
                    day === 16 ? 'bg-emerald-100 text-emerald-800 font-bold' :
                    day === 23 ? 'bg-purple-100 text-purple-900 font-bold' : ''
                  }`}
                >
                  {day}
                </span>
              ))}
            </div>

            <div className="mt-4 pt-3 border-t border-gray-100 text-[11px] text-gray-500 flex items-center justify-center gap-1.5 font-medium">
              <span className="w-2 h-2 rounded-full bg-emerald-500"></span> 3 events this month
            </div>
          </Card>

          {/* Schedule Section & Countdown Banner */}
          <Card className="space-y-4">
            <div className="flex justify-between items-center">
              <h3 className="font-bold text-gray-900 text-sm tracking-tight">My schedule</h3>
              <a href="#" className="text-xs text-purple-600 font-bold hover:underline">See all</a>
            </div>

            <div className="space-y-3 text-xs">
              {[
                { time: 'MWF 8–9 AM', name: 'Intro to Computing', code: 'CS101' },
                { time: 'TTh 9–10:30', name: 'Programming 1', code: 'CS102' },
                { time: 'MWF 10–11 AM', name: 'Understanding Self', code: 'GE101' },
              ].map((item, idx) => (
                <div key={idx} className="flex items-start gap-3 pl-2 border-l-2 border-purple-600">
                  <span className="text-gray-400 text-[11px] font-medium w-20 shrink-0">{item.time}</span>
                  <div>
                    <p className="font-bold text-gray-900 leading-tight">{item.name}</p>
                    <p className="text-[10px] text-gray-400 font-mono">{item.code}</p>
                  </div>
                </div>
              ))}
            </div>

            {/* Countdown Banner */}
            <div className="bg-gray-900 text-white p-4 rounded-xl shadow-md mt-4">
              <p className="text-[10px] text-gray-400 font-medium uppercase tracking-wider mb-1">Next lesson in</p>
              <p className="text-xl font-mono font-bold tracking-widest text-white mb-1">00 : 42 : 18</p>
              <p className="text-xs text-gray-300 font-medium">Intro to Computing · CS101</p>
            </div>
          </Card>

        </div>

      </div>

    </div>
  );
}