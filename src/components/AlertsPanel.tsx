'use client';

interface Alert {
  id: string;
  type: 'urgent' | 'warning' | 'info';
  title: string;
  subtitle: string;
}

interface AlertsPanelProps {
  alerts: Alert[];
  moodData: number[];
}

const ALERT_STYLES = {
  urgent: { bg: 'bg-red-500/10', border: 'border-red-500/20', dot: 'bg-red-500', text: 'text-red-400' },
  warning: { bg: 'bg-orange-500/10', border: 'border-orange-500/20', dot: 'bg-orange-400', text: 'text-orange-400' },
  info: { bg: 'bg-[#6c63ff]/10', border: 'border-[#6c63ff]/20', dot: 'bg-[#6c63ff]', text: 'text-[#6c63ff]' },
};

const URGENT_LABEL = { urgent: '!', warning: '!', info: 'i' };
const DAY_LABELS = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

export default function AlertsPanel({ alerts, moodData }: AlertsPanelProps) {
  const urgentCount = alerts.filter((a) => a.type === 'urgent').length;
  const maxBarH = 56;

  return (
    <div className="space-y-4">
      <div className="bg-[#0a0d16] border border-white/5 rounded-xl p-5">
        <div className="flex items-center justify-between mb-4">
          <div>
            <h2 className="font-semibold text-white">Active Alerts</h2>
            <p className="text-xs text-[#5a6080] mt-0.5">Requires attention</p>
          </div>
          {urgentCount > 0 && (
            <span className="text-xs font-bold text-red-400 bg-red-500/10 px-2 py-1 rounded-full">{urgentCount} urgent</span>
          )}
        </div>
        <div className="space-y-2">
          {alerts.map((alert) => {
            const s = ALERT_STYLES[alert.type];
            return (
              <div key={alert.id} className={`flex items-start gap-3 p-3 rounded-lg border ${s.bg} ${s.border}`}>
                <div className={`w-5 h-5 rounded-full ${s.dot} flex items-center justify-center text-[10px] font-bold text-white flex-shrink-0 mt-0.5`}>
                  {URGENT_LABEL[alert.type]}
                </div>
                <div>
                  <div className="text-sm font-medium text-white">{alert.title}</div>
                  <div className="text-xs text-[#5a6080] mt-0.5">{alert.subtitle}</div>
                </div>
              </div>
            );
          })}
        </div>
      </div>
      <div className="bg-[#0a0d16] border border-white/5 rounded-xl p-5">
        <h2 className="font-semibold text-white mb-1">Mood Signal · This Week</h2>
        <p className="text-xs text-[#5a6080] mb-4">Daily sentiment from journal entries</p>
        <div className="flex items-end justify-between gap-1" style={{ height: maxBarH + 8 }}>
          {moodData.map((val, i) => {
            const normalized = (val + 1) / 2;
            const h = Math.max(6, Math.round(normalized * maxBarH));
            const isToday = i === moodData.length - 1;
            const color = val > 0.3 ? '#3d9e6e' : val < -0.1 ? '#e05252' : '#5a6080';
            return (
              <div key={i} className="flex flex-col items-center gap-1 flex-1">
                <div className="w-full rounded-t-md transition-all" style={{ height: h, backgroundColor: isToday ? '#6c63ff40' : color, borderTop: isToday ? '2px solid #6c63ff' : 'none' }} />
                <span className="text-[9px] text-[#3a3f5c] font-medium">{DAY_LABELS[i]}</span>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
