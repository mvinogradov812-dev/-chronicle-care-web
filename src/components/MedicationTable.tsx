'use client';

interface Medication {
  name: string;
  dose: string;
  days: (boolean | null)[];
  rate: number;
}

interface MedicationTableProps {
  medications: Medication[];
}

const DAY_LABELS = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

export default function MedicationTable({ medications }: MedicationTableProps) {
  return (
    <div className="bg-[#0a0d16] border border-white/5 rounded-xl p-6">
      <div className="flex items-center justify-between mb-1">
        <div>
          <h2 className="font-semibold text-white">Medication Schedule</h2>
          <p className="text-xs text-[#5a6080] mt-0.5">Mon–Sun · Self-reported by client</p>
        </div>
        <div className="flex items-center gap-3 text-sm text-[#5a6080]">
          <button className="hover:text-white transition-colors">‹</button>
          <span className="text-white font-medium">Mar 3 – Mar 9</span>
          <button className="hover:text-white transition-colors">›</button>
        </div>
      </div>
      <div className="mt-5">
        <div className="grid grid-cols-[1fr_repeat(7,_36px)_60px] gap-1 mb-2">
          <div className="text-[10px] font-semibold tracking-widest text-[#3a3f5c] uppercase">MEDICATION</div>
          {DAY_LABELS.map((d) => (
            <div key={d} className="text-[10px] font-semibold tracking-widest text-[#3a3f5c] uppercase text-center">{d}</div>
          ))}
          <div className="text-[10px] font-semibold tracking-widest text-[#3a3f5c] uppercase text-right">RATE</div>
        </div>
        <div className="space-y-1">
          {medications.map((med, i) => (
            <div key={i} className="grid grid-cols-[1fr_repeat(7,_36px)_60px] gap-1 items-center py-3 border-t border-white/5">
              <div>
                <div className="text-sm font-medium text-white">{med.name}</div>
                <div className="text-xs text-[#5a6080]">{med.dose}</div>
              </div>
              {med.days.map((day, j) => (
                <div key={j} className="flex items-center justify-center">
                  {day === null ? (
                    <div className="w-6 h-6 rounded-md bg-[#6c63ff]/20 border border-[#6c63ff]/30" />
                  ) : day ? (
                    <span className="text-[#3d9e6e] text-base">✓</span>
                  ) : (
                    <span className="text-red-400 text-base">✗</span>
                  )}
                </div>
              ))}
              <div className={`text-right text-sm font-semibold ${med.rate >= 80 ? 'text-[#3d9e6e]' : 'text-[#e8a23a]'}`}>
                {med.rate}%
              </div>
            </div>
          ))}
        </div>
        <div className="flex items-center justify-between pt-4 border-t border-white/5 mt-2">
          <span className="text-sm text-[#5a6080]">Overall weekly compliance</span>
          <span className="text-sm font-semibold text-[#3d9e6e]">81%</span>
        </div>
      </div>
    </div>
  );
}
