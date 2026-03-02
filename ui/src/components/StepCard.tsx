import type { ReactNode } from "react";

export type StepStatus = "pending" | "ready" | "loading" | "done";

interface Props {
  index?: number;
  step?:  number;
  title:        string;
  description?: string;
  subtitle?:    string;
  status:       StepStatus;
  children?:    ReactNode;
}

const RING: Record<StepStatus, string> = {
  pending: "border-zinc-800",
  ready:   "border-indigo-500",
  loading: "border-indigo-400 shadow-indigo-900/50 shadow-lg",
  done:    "border-emerald-600",
};

const BADGE: Record<StepStatus, string> = {
  pending: "bg-zinc-800 text-zinc-500",
  ready:   "bg-indigo-900/60 text-indigo-300",
  loading: "bg-indigo-600 text-white",
  done:    "bg-emerald-900/60 text-emerald-400",
};

const LABEL: Record<StepStatus, string> = {
  pending: "waiting",
  ready:   "ready",
  loading: "signing…",
  done:    "done",
};

export function StepCard({ index, step, title, description, subtitle, status, children }: Props) {
  const num  = (index ?? step ?? 0) + 1;
  const desc = description ?? subtitle;

  return (
    <div className={`rounded-2xl border bg-zinc-900 p-5 transition-all duration-300 ${RING[status]}`}>
      <div className="flex items-start justify-between mb-1">
        <div className="flex items-center gap-3 min-w-0">
          <div className={`w-8 h-8 rounded-full flex-shrink-0 flex items-center justify-center text-sm font-bold transition-colors ${BADGE[status]}`}>
            {status === "done"
              ? "✓"
              : status === "loading"
              ? <span className="w-3.5 h-3.5 border-2 border-white border-t-transparent rounded-full animate-spin block" />
              : num}
          </div>
          <div className="min-w-0">
            <div className="font-semibold text-zinc-100 leading-snug">{title}</div>
            {desc && <div className="text-xs text-zinc-500 mt-0.5 leading-relaxed">{desc}</div>}
          </div>
        </div>
        <span className={`text-xs px-2 py-0.5 rounded-full font-medium shrink-0 ml-3 mt-0.5 ${BADGE[status]}`}>
          {LABEL[status]}
        </span>
      </div>
      {children && <div className="mt-4">{children}</div>}
    </div>
  );
}
