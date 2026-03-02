import { useState, useEffect, useRef } from "react";

interface ProofTimelineProps {
  active: boolean;
  onComplete?: (result: ProofTimelineResult) => void;
}

export interface ProofTimelineResult {
  proveMs: number;
  verifyMs: number;
  proofSizeKiB: number;
}

type Phase = "idle" | "building" | "proving" | "verifying" | "done";

const PHASE_LABELS: Record<Phase, string> = {
  idle: "Waiting…",
  building: "Building circuit (64 SHA-256 steps)…",
  proving: "Generating Binius64 proof…",
  verifying: "Verifying proof…",
  done: "Proof verified",
};

const PHASE_COLORS: Record<Phase, string> = {
  idle: "text-zinc-500",
  building: "text-blue-400",
  proving: "text-amber-400",
  verifying: "text-cyan-400",
  done: "text-emerald-400",
};

/**
 * Animated timeline showing Binius64 proof generation.
 *
 * Simulates realistic timings from the actual benchmark:
 *   Build: ~466ms, Prove: ~173ms, Verify: ~47ms
 */
export function ProofTimeline({ active, onComplete }: ProofTimelineProps) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [elapsed, setElapsed] = useState(0);
  const [result, setResult] = useState<ProofTimelineResult | null>(null);
  const intervalRef = useRef<ReturnType<typeof setInterval>>();
  const startRef = useRef(0);

  useEffect(() => {
    if (!active) {
      setPhase("idle");
      setElapsed(0);
      setResult(null);
      return;
    }

    startRef.current = performance.now();
    setPhase("building");

    intervalRef.current = setInterval(() => {
      setElapsed(performance.now() - startRef.current);
    }, 16);

    const timers = [
      setTimeout(() => setPhase("proving"), 120),
      setTimeout(() => setPhase("verifying"), 120 + 173),
      setTimeout(() => {
        setPhase("done");
        const res: ProofTimelineResult = {
          proveMs: 173.4,
          verifyMs: 46.7,
          proofSizeKiB: 283.5,
        };
        setResult(res);
        onComplete?.(res);
      }, 120 + 173 + 47),
    ];

    return () => {
      timers.forEach(clearTimeout);
      if (intervalRef.current) clearInterval(intervalRef.current);
    };
  }, [active, onComplete]);

  useEffect(() => {
    if (phase === "done" && intervalRef.current) {
      clearInterval(intervalRef.current);
    }
  }, [phase]);

  if (phase === "idle") return null;

  const phaseIdx = ["building", "proving", "verifying", "done"].indexOf(phase);

  return (
    <div className="rounded-xl border border-zinc-700 bg-zinc-900/80 p-4 font-mono text-xs">
      <div className="flex items-center gap-2 mb-3">
        <div className="flex items-center gap-1.5">
          <div className={`w-2 h-2 rounded-full ${phase === "done" ? "bg-emerald-400" : "bg-amber-400 animate-pulse"}`} />
          <span className={`font-semibold ${PHASE_COLORS[phase]}`}>
            {PHASE_LABELS[phase]}
          </span>
        </div>
        <span className="text-zinc-500 ml-auto">
          {elapsed > 0 ? `${elapsed.toFixed(0)}ms` : ""}
        </span>
      </div>

      {/* Progress bar */}
      <div className="flex gap-1 mb-3">
        {["Build", "Prove", "Verify"].map((label, i) => (
          <div key={label} className="flex-1">
            <div className="text-[10px] text-zinc-500 mb-1">{label}</div>
            <div className="h-1.5 rounded-full bg-zinc-800 overflow-hidden">
              <div
                className={`h-full rounded-full transition-all duration-150 ${
                  i < phaseIdx
                    ? "bg-emerald-500 w-full"
                    : i === phaseIdx && phase !== "done"
                    ? "bg-amber-500 w-2/3 animate-pulse"
                    : i === phaseIdx
                    ? "bg-emerald-500 w-full"
                    : "w-0"
                }`}
              />
            </div>
          </div>
        ))}
      </div>

      {/* Results */}
      {result && (
        <div className="grid grid-cols-3 gap-3 pt-2 border-t border-zinc-800">
          <div>
            <div className="text-zinc-500">Prove</div>
            <div className="text-amber-300 font-bold">{result.proveMs.toFixed(0)}ms</div>
          </div>
          <div>
            <div className="text-zinc-500">Verify</div>
            <div className="text-cyan-300 font-bold">{result.verifyMs.toFixed(0)}ms</div>
          </div>
          <div>
            <div className="text-zinc-500">Proof</div>
            <div className="text-zinc-300 font-bold">{result.proofSizeKiB.toFixed(0)} KiB</div>
          </div>
        </div>
      )}
    </div>
  );
}
