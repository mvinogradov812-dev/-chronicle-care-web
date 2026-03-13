'use client';

export default function DashboardHeader() {
  return (
    <div className="flex items-start justify-between">
      <div>
        <h1 className="text-2xl font-bold text-white tracking-tight">Client Dashboard</h1>
        <p className="text-sm text-[#5a6080] mt-1">
          Week of March 3–9, 2026 · <span className="text-[#3d9e6e]">● Last updated 2 min ago</span>
        </p>
      </div>
      <div className="flex items-center gap-3">
        <button className="flex items-center gap-2 px-4 py-2 rounded-lg border border-white/10 text-sm text-[#9099c0] hover:text-white hover:border-white/20 transition-all">
          <span>↓</span> Export PDF
        </button>
        <button className="flex items-center gap-2 px-4 py-2 rounded-lg bg-red-500/10 border border-red-500/20 text-sm text-red-400 hover:bg-red-500/20 transition-all">
          <span>🔔</span> 2 Active Alerts
        </button>
      </div>
    </div>
  );
}
