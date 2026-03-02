/**
 * SigningProgress
 *
 * Collapses N individual EIP-712 signing steps into a single cohesive widget.
 * Shows which stage each signature belongs to, progress through the queue,
 * and what the signature authorises in plain English.
 *
 * Usage:
 *   const [sigStep, setSigStep] = useState(-1);
 *   // then before each signXxx() call: setSigStep(n)
 *   <SigningProgress steps={STEPS} currentIndex={sigStep} />
 */

export interface SigStep {
  /** Human-readable group label, e.g. "Stage 1 — Sell on dip" */
  stage: string;
  /** What this specific signature authorises */
  label: string;
  /** Icon (emoji) for visual variety */
  icon?: string;
}

interface Props {
  steps:        SigStep[];
  /** Index of the signature currently being collected. -1 = not yet started. */
  currentIndex: number;
  /** Total signatures done (for display when currentIndex advances past last) */
}

function Dot({ done, active }: { done: boolean; active: boolean }) {
  if (done)
    return <span className="w-4 h-4 rounded-full bg-emerald-500 flex items-center justify-center text-[9px] text-white shrink-0">✓</span>;
  if (active)
    return <span className="w-4 h-4 rounded-full bg-indigo-500 flex items-center justify-center shrink-0">
      <span className="w-2 h-2 rounded-full bg-white animate-ping" />
    </span>;
  return <span className="w-4 h-4 rounded-full border border-zinc-600 bg-zinc-800 shrink-0" />;
}

export function SigningProgress({ steps, currentIndex }: Props) {
  if (steps.length === 0) return null;

  const doneCount = currentIndex < 0 ? 0 : Math.min(currentIndex, steps.length);
  const pct       = Math.round((doneCount / steps.length) * 100);

  // Group steps by stage name
  const groups: { stage: string; items: (SigStep & { idx: number })[] }[] = [];
  for (const [idx, s] of steps.entries()) {
    const last = groups[groups.length - 1];
    if (last && last.stage === s.stage) {
      last.items.push({ ...s, idx });
    } else {
      groups.push({ stage: s.stage, items: [{ ...s, idx }] });
    }
  }

  return (
    <div className="rounded-xl border border-zinc-700/60 bg-zinc-800/50 p-4 space-y-4">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className="text-base">🔐</span>
          <span className="text-sm font-semibold text-zinc-200">Strategy Setup</span>
        </div>
        <span className="text-xs text-zinc-400 font-mono">
          {doneCount}/{steps.length} signed
        </span>
      </div>

      {/* Progress bar */}
      <div className="h-1.5 rounded-full bg-zinc-700 overflow-hidden">
        <div
          className="h-full rounded-full bg-indigo-500 transition-all duration-500"
          style={{ width: `${pct}%` }}
        />
      </div>

      {/* Grouped signature list */}
      <div className="space-y-3">
        {groups.map((g) => {
          const anyActive = g.items.some((i) => i.idx === currentIndex);
          const allDone   = g.items.every((i) => i.idx < currentIndex);

          return (
            <div key={g.stage} className={`rounded-lg p-3 border transition-colors ${
              anyActive  ? "border-indigo-600/60 bg-indigo-950/30" :
              allDone    ? "border-emerald-800/40 bg-emerald-950/20" :
                           "border-zinc-700/40 bg-zinc-800/30"
            }`}>
              <div className={`text-xs font-semibold mb-2 ${
                anyActive ? "text-indigo-300" : allDone ? "text-emerald-400" : "text-zinc-500"
              }`}>
                {allDone && "✓ "}{g.stage}
              </div>
              <div className="space-y-1.5">
                {g.items.map((item) => {
                  const done   = item.idx < currentIndex;
                  const active = item.idx === currentIndex;
                  return (
                    <div key={item.idx} className={`flex items-center gap-2 text-xs transition-colors ${
                      active ? "text-indigo-200" : done ? "text-zinc-500" : "text-zinc-600"
                    }`}>
                      <Dot done={done} active={active} />
                      {item.icon && <span>{item.icon}</span>}
                      <span>{item.label}</span>
                      {active && <span className="ml-auto text-indigo-400 text-[10px] animate-pulse">awaiting wallet…</span>}
                    </div>
                  );
                })}
              </div>
            </div>
          );
        })}
      </div>

      {/* Footer hint */}
      {currentIndex >= 0 && currentIndex < steps.length && (
        <p className="text-[11px] text-zinc-600 text-center">
          Each signature is a scoped permission — no blanket approval ever leaves your wallet.
        </p>
      )}
      {currentIndex >= steps.length && (
        <p className="text-[11px] text-emerald-600 text-center font-medium">
          All permissions committed. Strategy is live — agent can go offline.
        </p>
      )}
    </div>
  );
}
