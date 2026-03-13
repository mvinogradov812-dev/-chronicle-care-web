'use client';

interface SidebarProps {
  activeNav: string;
  setActiveNav: (nav: string) => void;
}

const NAV_ITEMS = [
  { id: 'overview', label: 'OVERVIEW', isHeader: true },
  { id: 'dashboard', label: 'Dashboard', icon: '⊞' },
  { id: 'clients', label: 'My Clients', icon: '👤', badge: 4 },
  { id: 'monitoring', label: 'MONITORING', isHeader: true },
  { id: 'health', label: 'Health Tracking', icon: '📈' },
  { id: 'medication', label: 'Medication Log', icon: '🕐' },
  { id: 'alerts', label: 'Alerts', icon: '🔔', badge: 2, badgeColor: 'red' },
  { id: 'reports', label: 'REPORTS', isHeader: true },
  { id: 'weekly', label: 'Weekly Reports', icon: '📄' },
];

export default function Sidebar({ activeNav, setActiveNav }: SidebarProps) {
  return (
    <aside className="w-56 bg-[#0a0d16] border-r border-white/5 flex flex-col flex-shrink-0">
      <div className="p-5 border-b border-white/5">
        <div className="flex items-center gap-3">
          <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-[#6c63ff] to-[#4f46e5] flex items-center justify-center text-sm font-bold">C</div>
          <div>
            <div className="font-semibold text-sm tracking-wide">Chronicle</div>
            <div className="text-[10px] text-[#6c63ff] font-medium tracking-widest uppercase">Care</div>
          </div>
        </div>
      </div>
      <nav className="flex-1 p-3 space-y-0.5">
        {NAV_ITEMS.map((item) => {
          if (item.isHeader) {
            return (
              <div key={item.id} className="pt-4 pb-1 px-2">
                <span className="text-[10px] font-semibold tracking-widest text-[#3a3f5c] uppercase">{item.label}</span>
              </div>
            );
          }
          const isActive = activeNav === item.id;
          return (
            <button key={item.id} onClick={() => setActiveNav(item.id)}
              className={`w-full flex items-center gap-3 px-3 py-2 rounded-lg text-sm transition-all ${isActive ? 'bg-[#6c63ff]/15 text-white' : 'text-[#5a6080] hover:text-[#9099c0] hover:bg-white/3'}`}>
              <span className="text-base">{item.icon}</span>
              <span className="flex-1 text-left font-medium">{item.label}</span>
              {item.badge && (
                <span className={`text-[10px] font-bold px-1.5 py-0.5 rounded-full ${item.badgeColor === 'red' ? 'bg-red-500/20 text-red-400' : 'bg-[#6c63ff]/20 text-[#6c63ff]'}`}>
                  {item.badge}
                </span>
              )}
            </button>
          );
        })}
      </nav>
    </aside>
  );
}
