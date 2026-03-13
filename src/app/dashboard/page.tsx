'use client';

import { useState } from 'react';
import Sidebar from '@/components/Sidebar';
import DashboardHeader from '@/components/DashboardHeader';
import ClientTabs from '@/components/ClientTabs';
import StatsRow from '@/components/StatsRow';
import MedicationTable from '@/components/MedicationTable';
import AlertsPanel from '@/components/AlertsPanel';

const CLIENTS = [
  { id: '1', name: 'Eino Mäkinen', age: 74, status: 'good' as const },
  { id: '2', name: 'Aino Virtanen', age: 81, status: 'warning' as const },
  { id: '3', name: 'Paavo Leinonen', age: 68, status: 'good' as const },
  { id: '4', name: 'Liisa Koivisto', age: 77, status: 'alert' as const },
];

const MEDICATIONS = [
  { name: 'Metoprolol', dose: '50mg · Morning', days: [true, true, false, true, true, true, null], rate: 86 },
  { name: 'Amlodipine', dose: '5mg · Evening', days: [true, true, false, true, true, true, null], rate: 86 },
  { name: 'Atorvastatin', dose: '20mg · Evening', days: [true, false, true, true, true, true, null], rate: 86 },
  { name: 'Vitamin D', dose: '1000 IU · Morning', days: [false, false, true, true, true, true, null], rate: 67 },
];

const ALERTS = [
  { id: '1', type: 'urgent' as const, title: 'Metoprolol missed yesterday', subtitle: 'Thursday, Mar 6 · Morning dose' },
  { id: '2', type: 'warning' as const, title: 'Vitamin D — 2 consecutive misses', subtitle: 'Mon–Tue, Mar 3–4' },
  { id: '3', type: 'info' as const, title: 'No entries on Wednesday', subtitle: 'Mar 5 · Journal inactive' },
];

const MOOD_DATA = [1, 1, 0.4, -0.2, 1, 0.8, 0];

export default function Dashboard() {
  const [activeClient, setActiveClient] = useState('1');
  const [activeNav, setActiveNav] = useState('dashboard');

  return (
    <div className="flex h-screen bg-[#0f1117] text-white overflow-hidden">
      <Sidebar activeNav={activeNav} setActiveNav={setActiveNav} />
      <main className="flex-1 overflow-y-auto">
        <div className="p-8">
          <DashboardHeader />
          <div className="mt-6 p-3 rounded-xl bg-[#1a1d2e] border border-[#6c63ff]/20 text-sm text-[#a0a8c0] flex items-center gap-2">
            <span className="text-[#6c63ff]">🛡</span>
            <span><span className="text-white font-medium">Privacy-first:</span> You only see health records and mood signals. Financial and personal diary entries remain private to the client.</span>
          </div>
          <div className="mt-6">
            <ClientTabs clients={CLIENTS} activeClient={activeClient} setActiveClient={setActiveClient} />
          </div>
          <div className="mt-6"><StatsRow /></div>
          <div className="mt-6 grid grid-cols-[1fr_340px] gap-6">
            <MedicationTable medications={MEDICATIONS} />
            <AlertsPanel alerts={ALERTS} moodData={MOOD_DATA} />
          </div>
        </div>
      </main>
    </div>
  );
}
