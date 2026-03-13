'use client';

const STATS = [
  { label: 'MED COMPLIANCE', icon: '✓', value: '86%', valueColor: '#3d9e6e', sub: '↑ 12%  vs last week', subColor: '#3d9e6e' },
  { label: 'ACTIVE DAYS', icon: '👤', value: '6', valueSuffix: '/7', valueColor: '#ffffff', sub: 'Journal entries this week', subColor: '#5a6080' },
  { label: 'MOOD SIGNAL', icon: '♡', value: 'Good', valueColor: '#3d9e6e', sub: 'Mostly positive this week', subColor: '#5a6080' },
  { label: 'MISSED DOSES', icon: '🔔', value: '3', valueColor: '#e8a23a', sub: '↓ 5  vs last week', subColor: '#3d9e6e' },
];

export default function StatsRow() {
  return (
    <div className="grid grid-cols-4 gap-4">
      {STATS.map((stat, i) => (
        <div key={i} className="bg-[#0a0d16] border border-white/5 rounded-xl p-5 hover:border-white/10 transition-all">
          <div className="flex items-center gap-2 text-[10px] font-semibold tracking-widest text-[#3a3f5c] uppercase mb-3">
            <span>{stat.icon}</span>{stat.label}
          </div>
          <div className="flex items-baseline gap-1">
            <span className="text-3xl font-bold" style={{ color: stat.valueColor }}>{stat.value}</span>
            {stat.valueSuffix && <span className="text-lg text-[#3a3f5c] font-medium">{stat.valueSuffix}</span>}
          </div>
          <div className="mt-2 text-xs" style={{ color: stat.subColor }}>{stat.sub}</div>
        </div>
      ))}
    </div>
  );
}
