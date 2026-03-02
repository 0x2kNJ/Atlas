import { useState } from "react";

export function WithoutAtlasCard() {
  const [open, setOpen] = useState(false);

  return (
    <div className="rounded-2xl border border-zinc-800 bg-zinc-900/50 overflow-hidden">
      <button
        onClick={() => setOpen(o => !o)}
        className="w-full flex items-center justify-between px-5 py-3 text-xs text-zinc-500 hover:text-zinc-300 transition-colors"
      >
        <span className="flex items-center gap-2">
          <span className="text-red-500/70">⚠</span>
          What happens without Atlas?
        </span>
        <span className="font-mono text-zinc-700">{open ? "▲" : "▼"}</span>
      </button>

      {open && (
        <div className="border-t border-zinc-800 px-5 py-4">
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <FailureCard
              scenario="Agent goes offline"
              without="Loan deadline passes. No one repays. Default recorded."
              with="Keeper fires at deadline. Repayment executes from pre-committed vault position."
            />
            <FailureCard
              scenario="Agent key compromised"
              without="Attacker can drain the agent's account and abandon the loan."
              with="Capability token limits the agent to only the allowed adapter. Blast radius bounded."
            />
            <FailureCard
              scenario="Network congestion"
              without="Agent can't get a transaction through. Deadline missed."
              with="Keeper retries. Gas price covered by keeper reward. No agent action needed."
            />
            <FailureCard
              scenario="No credit history"
              without="Lender has no recourse. Must require collateral or refuse new agents."
              with="ZK proof of on-chain receipts. Credit tier on-chain. Verifiable by any lender."
            />
          </div>

          {/* Credit trajectory comparison */}
          <div className="mt-4 rounded-xl border border-zinc-800 bg-zinc-950/50 p-4">
            <p className="text-xs text-zinc-400 font-medium mb-3">Credit trajectory after 6 cycles</p>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5">
                <div className="text-xs text-red-400 font-medium flex items-center gap-1">
                  <span>✕</span> Without Atlas (one default)
                </div>
                <TierRow tier="NEW" amount="$500" active />
                <div className="text-xs text-zinc-700 pl-4">↓ default resets tier</div>
                <TierRow tier="NEW" amount="$500" danger />
              </div>
              <div className="space-y-1.5">
                <div className="text-xs text-emerald-400 font-medium flex items-center gap-1">
                  <span>✓</span> With Atlas (6 clean cycles)
                </div>
                <TierRow tier="BRONZE" amount="$2,000" done />
                <div className="text-xs text-zinc-500 pl-4">→ on track for SILVER</div>
                <TierRow tier="SILVER" amount="$10,000" preview />
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function FailureCard({ scenario, without, with: withAtlas }: { scenario: string; without: string; with: string }) {
  return (
    <div className="rounded-xl bg-zinc-950/60 border border-zinc-800 p-3">
      <div className="text-xs font-semibold text-zinc-300 mb-2">{scenario}</div>
      <div className="flex items-start gap-1.5 mb-1.5">
        <span className="text-red-500 text-xs mt-0.5 shrink-0">✕</span>
        <span className="text-xs text-zinc-600 leading-relaxed">{without}</span>
      </div>
      <div className="flex items-start gap-1.5">
        <span className="text-emerald-500 text-xs mt-0.5 shrink-0">✓</span>
        <span className="text-xs text-zinc-400 leading-relaxed">{withAtlas}</span>
      </div>
    </div>
  );
}

function TierRow({ tier, amount, active, done, danger, preview }: {
  tier: string; amount: string;
  active?: boolean; done?: boolean; danger?: boolean; preview?: boolean;
}) {
  const color = danger ? "text-red-400 border-red-800 bg-red-950/30"
    : done ? "text-emerald-400 border-emerald-800 bg-emerald-950/30"
    : preview ? "text-indigo-400 border-indigo-800 bg-indigo-950/30 opacity-70"
    : active ? "text-amber-400 border-amber-800 bg-amber-950/30"
    : "text-zinc-500 border-zinc-800";
  return (
    <div className={`flex items-center justify-between rounded-lg border px-3 py-1.5 text-xs ${color}`}>
      <span className="font-medium">{tier}</span>
      <span className="font-mono">{amount} max</span>
    </div>
  );
}
