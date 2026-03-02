/**
 * FlowDiagram
 *
 * Renders a horizontal sequence of condition → action nodes with arrows
 * to visually communicate what a strategy graph does at a glance.
 */

export interface FlowNode {
  /** Short label for the trigger/condition */
  condition: string;
  /** What happens when triggered */
  action: string;
  /** Optional outcome/result label */
  result?: string;
  /** Visual style: "warn" = orange, "danger" = red, "safe" = green, "neutral" = default */
  tone?: "warn" | "danger" | "safe" | "neutral";
}

interface Props {
  nodes: FlowNode[];
  /** If true, nodes are stacked vertically instead of horizontal */
  vertical?: boolean;
}

const TONE_COND: Record<string, string> = {
  warn:    "bg-amber-950/50 border-amber-700/50 text-amber-300",
  danger:  "bg-red-950/50 border-red-700/50 text-red-300",
  safe:    "bg-emerald-950/50 border-emerald-700/50 text-emerald-300",
  neutral: "bg-zinc-800/60 border-zinc-700 text-zinc-300",
};

const TONE_ACTION: Record<string, string> = {
  warn:    "text-amber-200",
  danger:  "text-red-200",
  safe:    "text-emerald-200",
  neutral: "text-zinc-200",
};

export function FlowDiagram({ nodes, vertical }: Props) {
  return (
    <div className={`flex ${vertical ? "flex-col" : "flex-wrap"} items-start gap-2 mt-4`}>
      {nodes.map((n, i) => {
        const tone = n.tone ?? "neutral";
        return (
          <div key={i} className="flex items-start gap-2">
            {/* Node */}
            <div className={`rounded-lg border px-3 py-2 text-xs min-w-[120px] ${TONE_COND[tone]}`}>
              <div className="font-medium text-[10px] uppercase tracking-wide opacity-60 mb-0.5">
                {i === 0 ? "trigger" : `stage ${i + 1}`}
              </div>
              <div className="font-semibold leading-snug">{n.condition}</div>
              <div className={`mt-1 font-medium ${TONE_ACTION[tone]}`}>→ {n.action}</div>
              {n.result && <div className="mt-0.5 text-zinc-500 text-[10px]">{n.result}</div>}
            </div>

            {/* Arrow connector (not after last node) */}
            {i < nodes.length - 1 && (
              <div className={`flex-shrink-0 ${vertical ? "mt-2 ml-8 rotate-90" : "mt-5"}`}>
                <svg width="20" height="12" viewBox="0 0 20 12" className="text-zinc-600">
                  <path d="M0 6 H14 M10 1 L18 6 L10 11" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}
