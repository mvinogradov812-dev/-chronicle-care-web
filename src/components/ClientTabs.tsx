'use client';

interface Client {
  id: string;
  name: string;
  age: number;
  status: 'good' | 'warning' | 'alert';
}

interface ClientTabsProps {
  clients: Client[];
  activeClient: string;
  setActiveClient: (id: string) => void;
}

const STATUS_COLORS = {
  good: '#3d9e6e',
  warning: '#e8a23a',
  alert: '#e05252',
};

export default function ClientTabs({ clients, activeClient, setActiveClient }: ClientTabsProps) {
  return (
    <div className="flex gap-2">
      {clients.map((client) => {
        const isActive = activeClient === client.id;
        return (
          <button key={client.id} onClick={() => setActiveClient(client.id)}
            className={`flex items-center gap-2 px-4 py-2 rounded-full text-sm font-medium transition-all border ${isActive ? 'bg-[#1a1d2e] border-[#6c63ff]/40 text-white' : 'bg-transparent border-white/10 text-[#5a6080] hover:text-[#9099c0] hover:border-white/20'}`}>
            <span className="w-2 h-2 rounded-full flex-shrink-0" style={{ backgroundColor: STATUS_COLORS[client.status] }} />
            {client.name}, {client.age}
          </button>
        );
      })}
    </div>
  );
}
