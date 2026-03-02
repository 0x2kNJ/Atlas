import type { ReactNode } from "react";

// ── Scenario ID types ─────────────────────────────────────────────────────────

/** ClawLoan two-tab scenarios */
export type ClawloanId = "clawloan" | "capital-provider";

/** Core protocol capability demos */
export type ProtocolId =
  | "dms"
  | "orchestration"
  | "stoploss"
  | "publishkey"
  | "liquidation"
  | "zkpassport"
  | "mofn";

/** Multi-stage lending strategy demos */
export type StrategyGraphId =
  | "sg-chained"
  | "sg-leveraged-long"
  | "sg-deleverage"
  | "sg-self-repaying"
  | "sg-collateral-rotation"
  | "sg-refi"
  | "sg-dca";

export type ScenarioId = ClawloanId | ProtocolId | StrategyGraphId;

// ── Helpers ───────────────────────────────────────────────────────────────────

const CLAWLOAN_IDS: ClawloanId[] = ["clawloan", "capital-provider"];
const PROTOCOL_IDS: ProtocolId[] = [
  "dms", "orchestration", "stoploss", "publishkey", "liquidation", "zkpassport", "mofn",
];
const STRATEGY_IDS: StrategyGraphId[] = [
  "sg-chained", "sg-leveraged-long", "sg-deleverage",
  "sg-self-repaying", "sg-collateral-rotation", "sg-refi", "sg-dca",
];

export function isClawloan(id: ScenarioId): id is ClawloanId {
  return (CLAWLOAN_IDS as string[]).includes(id);
}
export function isProtocol(id: ScenarioId): id is ProtocolId {
  return (PROTOCOL_IDS as string[]).includes(id);
}
export function isStrategyGraph(id: ScenarioId): id is StrategyGraphId {
  return (STRATEGY_IDS as string[]).includes(id);
}

// Keep for backwards compatibility
export type CoreScenarioId = ClawloanId | ProtocolId;

// ── Sub-scenario data ─────────────────────────────────────────────────────────

interface SubItem { id: ScenarioId; icon: string; label: string; desc: string; }

const CLAWLOAN_TABS: SubItem[] = [
  { id: "clawloan",          icon: "🦞", label: "Borrow",           desc: "AI agent borrows against ZK credit proof — loan auto-repays via keeper" },
  { id: "capital-provider",  icon: "🏦", label: "Lend",             desc: "Institutional lender funds the pool, earns yield, protected by Atlas keeper" },
];

const PROTOCOL_SCENARIOS: SubItem[] = [
  { id: "dms",           icon: "💀", label: "Dead Man's Switch",  desc: "Treasury protected by liveness-independent failsafe envelope" },
  { id: "orchestration", icon: "🤖", label: "Sub-agent Fleet",    desc: "Orchestrator delegates budget caps across multiple sub-agents" },
  { id: "stoploss",      icon: "🛡️", label: "Stop-Loss",          desc: "Price-triggered WETH→USDC protective put, no counterparty" },
  { id: "publishkey",    icon: "🔑", label: "Publish the Key",    desc: "Live key-compromise demo — bounded damage, instant revocation" },
  { id: "liquidation",   icon: "🏦", label: "Liquidation Engine", desc: "Aave-style liquidation via shared Atlas keeper network" },
  { id: "zkpassport",    icon: "🎫", label: "ZK Credit Passport", desc: "Portable credit tier unlocks limits across any protocol" },
  { id: "mofn",          icon: "🗳️", label: "M-of-N Consensus",  desc: "3-of-5 agent approval required for institutional trades" },
];

const STRATEGY_SCENARIOS: SubItem[] = [
  { id: "sg-chained",             icon: "🔗", label: "Chained Graph",       desc: "Two-stage sell/rebuy — original chained envelope demo" },
  { id: "sg-leveraged-long",      icon: "📈", label: "Leveraged Long",      desc: "Exit high, rebuy low, end with more WETH than you started" },
  { id: "sg-deleverage",          icon: "🪜", label: "Deleverage Ladder",   desc: "3 parallel exit tranches at successively lower price bands" },
  { id: "sg-self-repaying",       icon: "🌱", label: "Self-Repaying Loan",  desc: "Yield harvest auto-repays the loan — no agent online required" },
  { id: "sg-collateral-rotation", icon: "🔄", label: "Collateral Rotation", desc: "WETH↔USDC collateral rebalances autonomously on price bands" },
  { id: "sg-refi",                icon: "🛡️", label: "Refi Pipeline",       desc: "Emergency exit + instant refinance at 50% safer LTV" },
  { id: "sg-dca",                 icon: "💹", label: "Leveraged DCA",       desc: "Borrow → buy the dip → sell recovery → repay → keep profit" },
];

// ── Nav component ─────────────────────────────────────────────────────────────

type Group = "clawloan" | "protocol" | "strategy";

function activeGroup(id: ScenarioId): Group {
  if (isClawloan(id))  return "clawloan";
  if (isProtocol(id))  return "protocol";
  return "strategy";
}

function activeDesc(id: ScenarioId): string {
  const cl = CLAWLOAN_TABS.find(s => s.id === id);
  if (cl) return cl.desc;
  const p = PROTOCOL_SCENARIOS.find(s => s.id === id);
  if (p) return p.desc;
  return STRATEGY_SCENARIOS.find(s => s.id === id)?.desc ?? "";
}

interface Props {
  active:   ScenarioId;
  onChange: (id: ScenarioId) => void;
}

export function ScenarioNav({ active, onChange }: Props) {
  const group = activeGroup(active);

  const topBtn = (
    id:       Group,
    icon:     string,
    label:    string,
    tag:      string,
    color:    string,
    bg:       string,
    border:   string,
    onClick: () => void,
  ) => (
    <button key={id} onClick={onClick}
      className={`flex items-center gap-2 px-3 py-2 rounded-xl text-sm font-medium border
        transition-all duration-200 whitespace-nowrap shrink-0
        ${group === id
          ? `${bg} ${border} ${color}`
          : "bg-transparent border-transparent text-zinc-500 hover:text-zinc-300 hover:bg-zinc-800/50"
        }`}>
      <span className="text-base">{icon}</span>
      <span>{label}</span>
      <span className={`text-xs font-normal px-1.5 py-0.5 rounded-full ${
        group === id ? "bg-white/10" : "bg-zinc-800"} text-zinc-400`}>
        {tag}
      </span>
    </button>
  );

  return (
    <div className="border-b border-zinc-800 bg-zinc-950">

      {/* ── Row 1: three top-level groups ── */}
      <div className="px-6 py-3">
        <div className="max-w-7xl mx-auto flex items-center gap-3 overflow-x-auto">

          {topBtn("clawloan", "🦞", "ClawLoan", "2",
            "text-indigo-400", "bg-indigo-950/40", "border-indigo-700",
            () => onChange(group === "clawloan" ? active as ClawloanId : "clawloan"),
          )}

          {topBtn("protocol", "⚙️", "Protocol", "7",
            "text-cyan-400", "bg-cyan-950/40", "border-cyan-700",
            () => onChange(group === "protocol" ? active as ProtocolId : "dms"),
          )}

          {topBtn("strategy", "🧠", "Strategy Graph", "7",
            "text-emerald-400", "bg-emerald-950/40", "border-emerald-700",
            () => onChange(group === "strategy" ? active as StrategyGraphId : "sg-self-repaying"),
          )}

          {/* Right: active scenario description */}
          <div className="ml-auto hidden md:flex items-center shrink-0 border-l border-zinc-800 pl-4">
            <span className="text-xs text-zinc-500 max-w-xs">{activeDesc(active)}</span>
          </div>
        </div>
      </div>

      {/* ── Row 2: sub-nav (shown for all groups) ── */}
      {(() => {
        const items =
          group === "clawloan"  ? CLAWLOAN_TABS :
          group === "protocol"  ? PROTOCOL_SCENARIOS :
          STRATEGY_SCENARIOS;
        const label =
          group === "clawloan"  ? "Mode:" :
          group === "protocol"  ? "Capability:" :
          "Strategy:";
        const activeColor =
          group === "clawloan"  ? "bg-indigo-950/50 border-indigo-600 text-indigo-300" :
          group === "protocol"  ? "bg-cyan-950/50 border-cyan-600 text-cyan-300" :
          "bg-emerald-950/50 border-emerald-600 text-emerald-300";
        return (
          <div className="border-t border-zinc-800/60 bg-zinc-900/40 px-6 py-2">
            <div className="max-w-7xl mx-auto flex items-center gap-2 overflow-x-auto">
              <span className="text-xs text-zinc-600 font-medium shrink-0 mr-1">{label}</span>
              {items.map(s => (
                <button key={s.id} onClick={() => onChange(s.id)}
                  className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium
                    border transition-all duration-150 whitespace-nowrap shrink-0
                    ${active === s.id
                      ? activeColor
                      : "bg-transparent border-transparent text-zinc-500 hover:text-zinc-300 hover:bg-zinc-800/40"
                    }`}>
                  <span>{s.icon}</span>
                  <span>{s.label}</span>
                </button>
              ))}
            </div>
          </div>
        );
      })()}
    </div>
  );
}

/** Renders children only when the active scenario matches. */
export function ScenarioPane({ id, active, children }: { id: ScenarioId; active: ScenarioId; children: ReactNode }) {
  if (id !== active) return null;
  return <>{children}</>;
}
