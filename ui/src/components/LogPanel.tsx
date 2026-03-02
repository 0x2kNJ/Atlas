interface LogEntry {
  id:      number;
  ts:      number;
  level:   "info" | "success" | "error" | "warn";
  message: string;
}

const COLORS = {
  info:    "text-zinc-400",
  success: "text-emerald-400",
  error:   "text-red-400",
  warn:    "text-amber-400",
};

const PREFIX = {
  info:    "›",
  success: "✓",
  error:   "✗",
  warn:    "⚠",
};

interface Props {
  entries: LogEntry[];
}

export function LogPanel({ entries }: Props) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 h-48 overflow-y-auto font-mono text-xs space-y-1">
      {entries.length === 0 && (
        <span className="text-zinc-600">activity log — transactions and events appear here</span>
      )}
      {[...entries].reverse().map((e) => (
        <div key={e.id} className={`flex gap-2 ${COLORS[e.level]}`}>
          <span className="shrink-0 w-4">{PREFIX[e.level]}</span>
          <span className="text-zinc-600">{new Date(e.ts).toLocaleTimeString()}</span>
          <span>{e.message}</span>
        </div>
      ))}
    </div>
  );
}

export type { LogEntry };
