interface Props {
  loanAmount:      bigint; // USDC 6-dec
  debt:            bigint;
  positionSpent:   boolean;
  envelopeActive:  boolean;
  keeperFeeEarned: bigint;
}

const fmt = (n: bigint) => (Number(n) / 1e6).toFixed(2);

export function LenderPanel({ loanAmount, debt, positionSpent, envelopeActive, keeperFeeEarned }: Props) {
  const apy          = 5;
  const annualEarning = (Number(loanAmount) / 1e6) * (apy / 100);
  const profitShare  = (Number(loanAmount) / 1e6) * 0.05; // 5% profit share per repayment

  const status = positionSpent
    ? "repaid"
    : envelopeActive
    ? "protected"
    : debt > 0n
    ? "outstanding"
    : "idle";

  const statusConfig = {
    repaid:      { label: "Loan Repaid ✓",    color: "text-emerald-400", dot: "bg-emerald-400" },
    protected:   { label: "Atlas Protected",  color: "text-indigo-400",  dot: "bg-indigo-400 animate-pulse" },
    outstanding: { label: "Outstanding",      color: "text-red-400",     dot: "bg-red-400" },
    idle:        { label: "No Active Loan",   color: "text-zinc-500",    dot: "bg-zinc-600" },
  }[status];

  return (
    <div className="rounded-2xl border border-zinc-700 bg-zinc-900 p-5">
      {/* Header */}
      <div className="flex items-center gap-2 mb-4">
        <span className="text-lg">🏦</span>
        <div>
          <h3 className="text-sm font-semibold text-zinc-200">Lender Perspective</h3>
          <p className="text-xs text-zinc-500">Clawloan Pool — 5% APY</p>
        </div>
        <div className="ml-auto flex items-center gap-1.5">
          <span className={`w-1.5 h-1.5 rounded-full ${statusConfig.dot}`} />
          <span className={`text-xs font-medium ${statusConfig.color}`}>{statusConfig.label}</span>
        </div>
      </div>

      {/* Loan metrics */}
      <div className="grid grid-cols-2 gap-2 mb-4">
        <MetricCard
          label="Loan Funded"
          value={`$${fmt(loanAmount)}`}
          sub="USDC principal"
          color="text-zinc-200"
        />
        <MetricCard
          label="Annual Yield (5% APY)"
          value={`$${annualEarning.toFixed(2)}`}
          sub="per loan cycle"
          color="text-emerald-400"
        />
        <MetricCard
          label="5% Profit Share"
          value={`$${profitShare.toFixed(2)}`}
          sub="per repayment event"
          color="text-amber-400"
        />
        <MetricCard
          label="Pool TVL (simulated)"
          value="$10,000,000"
          sub="total lent across agents"
          color="text-indigo-400"
        />
      </div>

      {/* Atlas protection guarantee */}
      <div className={`rounded-xl border p-3 mb-3 ${
        status === "repaid"
          ? "border-emerald-800/40 bg-emerald-950/20"
          : status === "protected"
          ? "border-indigo-800/40 bg-indigo-950/20"
          : "border-zinc-800 bg-zinc-800/40"
      }`}>
        <p className="text-xs font-medium text-zinc-300 mb-1.5">Atlas Enforcement Guarantee</p>
        <ul className="space-y-1 text-xs text-zinc-500">
          <li className="flex items-start gap-1.5">
            <span className={status !== "idle" ? "text-emerald-500 mt-0.5" : "text-zinc-700 mt-0.5"}>✓</span>
            <span>Repayment enforced by keeper even if agent is offline</span>
          </li>
          <li className="flex items-start gap-1.5">
            <span className={status !== "idle" ? "text-emerald-500 mt-0.5" : "text-zinc-700 mt-0.5"}>✓</span>
            <span>Vault position encumbered — agent cannot withdraw before repayment</span>
          </li>
          <li className="flex items-start gap-1.5">
            <span className={status !== "idle" ? "text-emerald-500 mt-0.5" : "text-zinc-700 mt-0.5"}>✓</span>
            <span>Capability bounds: agent cannot spend more than debtCap via any path</span>
          </li>
          <li className="flex items-start gap-1.5">
            <span className="text-emerald-500 mt-0.5">✓</span>
            <span>ZK credit proof — repayment history verifiable without revealing identity</span>
          </li>
        </ul>
      </div>

      {/* Key compromise invariant */}
      <details className="group">
        <summary className="text-xs text-zinc-500 cursor-pointer hover:text-zinc-300 transition-colors select-none flex items-center gap-1">
          <span className="group-open:rotate-90 transition-transform inline-block">▶</span>
          What if the agent's key is compromised?
        </summary>
        <div className="mt-2 rounded-xl border border-zinc-800 bg-zinc-800/30 p-3 space-y-2 text-xs">
          <div className="grid grid-cols-2 gap-2">
            <div className="rounded-lg bg-red-950/30 border border-red-900/30 p-2">
              <p className="text-red-400 font-medium mb-1">Without Atlas</p>
              <p className="text-zinc-500">Attacker drains entire wallet. Loan unpaid. Lender loses principal.</p>
            </div>
            <div className="rounded-lg bg-emerald-950/30 border border-emerald-900/30 p-2">
              <p className="text-emerald-400 font-medium mb-1">With Atlas</p>
              <p className="text-zinc-500">Attacker can only execute the pre-signed intent. Loan is repaid. Surplus returned to vault.</p>
            </div>
          </div>
          <p className="text-zinc-600">
            The capability constraint bounds the attacker to at most{" "}
            <span className="font-mono text-zinc-400">${fmt(loanAmount)} USDC</span>{" "}
            spend via the registered adapter — the exact debt repayment. No more.
          </p>
        </div>
      </details>

      {keeperFeeEarned > 0n && (
        <div className="mt-3 rounded-lg border border-emerald-800/30 bg-emerald-950/20 px-3 py-2 text-xs flex items-center justify-between">
          <span className="text-zinc-500">Profit share auto-committed</span>
          <span className="text-emerald-400 font-medium">{(Number(keeperFeeEarned) / 1e6).toFixed(3)} USDC → pool</span>
        </div>
      )}
    </div>
  );
}

function MetricCard({ label, value, sub, color }: { label: string; value: string; sub: string; color: string }) {
  return (
    <div className="rounded-lg bg-zinc-800/50 p-3">
      <div className="text-xs text-zinc-500 mb-1">{label}</div>
      <div className={`text-base font-bold ${color}`}>{value}</div>
      <div className="text-xs text-zinc-600 mt-0.5">{sub}</div>
    </div>
  );
}
