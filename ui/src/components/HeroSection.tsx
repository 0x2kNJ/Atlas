interface Props {
  onDismiss: () => void;
}

export function HeroSection({ onDismiss }: Props) {
  return (
    <div className="relative rounded-2xl border border-indigo-800/40 bg-gradient-to-br from-indigo-950/60 via-zinc-950 to-zinc-950 p-8 overflow-hidden">
      {/* Subtle grid bg */}
      <div className="absolute inset-0 opacity-[0.03]" style={{
        backgroundImage: "linear-gradient(#6366f1 1px, transparent 1px), linear-gradient(90deg, #6366f1 1px, transparent 1px)",
        backgroundSize: "40px 40px"
      }} />

      <div className="relative">
        {/* Tag */}
        <div className="flex items-center gap-2 mb-5">
          <span className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-indigo-900/60 border border-indigo-700/50 text-indigo-300 text-xs font-medium">
            <span className="w-1.5 h-1.5 rounded-full bg-indigo-400 animate-pulse" />
            Pre-Seed Demo — Atlas Protocol × Clawloan
          </span>
        </div>

        {/* Headline */}
        <h2 className="text-3xl font-bold text-white mb-3 leading-tight tracking-tight">
          AI agents that repay their loans,<br />
          <span className="text-indigo-400">even when offline.</span>
        </h2>
        <p className="text-zinc-400 text-sm mb-8 max-w-xl leading-relaxed">
          Clawloan offers uncollateralized micro-loans to AI agents based on credit history.
          Atlas solves the liveness problem: repayments are cryptographically pre-committed so they
          execute at deadline regardless of agent availability, network faults, or compromise.
        </p>

        {/* Three key claims */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-8">
          <Claim
            icon="🔒"
            title="Pre-committed repayment"
            body="Agent signs once. Vault position is encumbered. Keeper can trigger permissionlessly at deadline — no agent needed."
          />
          <Claim
            icon="📈"
            title="Credit tier progression"
            body="Each proven repayment (ZK-verified on-chain) upgrades the agent's tier and unlocks larger borrowing limits."
          />
          <Claim
            icon="⚡"
            title="Liveness-independent"
            body="The enforcement rail. Separate from wallet delegation. Works even if the agent key is compromised, jailbroken, or destroyed."
          />
        </div>

        {/* Stack diagram */}
        <div className="border border-zinc-800 rounded-xl bg-zinc-900/60 p-4 mb-6">
          <p className="text-xs text-zinc-500 uppercase tracking-wider mb-3">Architecture</p>
          <div className="grid grid-cols-3 gap-2 text-xs">
            <StackLayer label="Wallet Delegation" sub="ERC-7710 · consent rail" color="border-zinc-700 text-zinc-400" />
            <StackLayer label="Atlas Protocol" sub="enforcement rail ← this demo" color="border-indigo-600/60 text-indigo-300 bg-indigo-950/30" highlight />
            <StackLayer label="Clawloan / DEX / Aave" sub="liquidity venues" color="border-zinc-700 text-zinc-400" />
          </div>
        </div>

        {/* Market numbers */}
        <div className="flex items-center gap-6 mb-6">
          <Metric label="2 academic papers" sub="SSRN pre-print, Feb 2026" />
          <span className="text-zinc-700 text-lg">·</span>
          <Metric label="159 passing tests" sub="CapabilityKernel + Registry + Vault" />
          <span className="text-zinc-700 text-lg">·</span>
          <Metric label="Phase 1 pre-audit" sub="Q2 2026 target" />
          <span className="text-zinc-700 text-lg">·</span>
          <Metric label="Aztec-ready" sub="commitment model maps to ZK notes" />
        </div>

        <div className="flex items-center gap-3">
          <button
            onClick={onDismiss}
            className="px-5 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors"
          >
            Run the demo →
          </button>
          <a
            href="?role=keeper"
            target="_blank"
            rel="noopener noreferrer"
            className="px-5 py-2 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-300 text-sm font-medium transition-colors border border-zinc-700"
          >
            Open Keeper Mode →
          </a>
        </div>
      </div>
    </div>
  );
}

function Claim({ icon, title, body }: { icon: string; title: string; body: string }) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900/50 p-4">
      <div className="text-2xl mb-2">{icon}</div>
      <div className="text-sm font-semibold text-zinc-200 mb-1">{title}</div>
      <div className="text-xs text-zinc-500 leading-relaxed">{body}</div>
    </div>
  );
}

function StackLayer({ label, sub, color, highlight }: { label: string; sub: string; color: string; highlight?: boolean }) {
  return (
    <div className={`rounded-lg border p-3 text-center ${color} ${highlight ? "ring-1 ring-indigo-500/30" : ""}`}>
      <div className="font-semibold text-xs mb-0.5">{label}</div>
      <div className="text-zinc-600 text-xs">{sub}</div>
    </div>
  );
}

function Metric({ label, sub }: { label: string; sub: string }) {
  return (
    <div>
      <div className="text-sm font-bold text-zinc-200">{label}</div>
      <div className="text-xs text-zinc-600">{sub}</div>
    </div>
  );
}
