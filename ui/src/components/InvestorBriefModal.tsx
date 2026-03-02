interface Props {
  onClose: () => void;
}

export function InvestorBriefModal({ onClose }: Props) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-sm p-4">
      <div className="relative bg-zinc-900 border border-zinc-700 rounded-3xl max-w-2xl w-full max-h-[90vh] overflow-y-auto">
        <div className="sticky top-0 bg-zinc-900 border-b border-zinc-800 px-8 py-4 flex items-center justify-between rounded-t-3xl">
          <div>
            <h2 className="text-base font-bold text-zinc-100">Atlas Protocol — Investor Brief</h2>
            <p className="text-xs text-zinc-500">February 2026 · Pre-Seed</p>
          </div>
          <button onClick={onClose} className="text-zinc-500 hover:text-zinc-200 text-lg transition-colors">✕</button>
        </div>

        <div className="px-8 py-6 space-y-7">

          {/* Problem */}
          <Section title="The Problem">
            <BulletList items={[
              "AI agents managing on-chain assets cannot guarantee liveness — they go offline, get compromised, or are replaced.",
              "Credit-based lending (e.g. Clawloan) requires agents to repay loans at deadline. A sleeping agent = default.",
              "Existing delegation standards (ERC-7710, session keys) solve consent, not enforcement. An agent with a valid delegation and a dead server still misses the deadline.",
            ]} />
          </Section>

          {/* Solution */}
          <Section title="The Solution: Atlas Protocol">
            <p className="text-sm text-zinc-400 mb-3">
              Atlas is a stateless agent authorization and conditional settlement layer. It introduces a clean
              separation between four primitives every existing protocol conflates:
            </p>
            <div className="grid grid-cols-2 gap-2 mb-3">
              {[
                ["Custody", "SingletonVault — commitment-based positions, not balances"],
                ["Identity", "Capability tokens — off-chain EIP-712, zero gas to grant/revoke"],
                ["Authorization", "CapabilityKernel — 18-step constraint enforcement on every execution"],
                ["Enforcement", "EnvelopeRegistry — pre-committed conditional execution by any keeper"],
              ].map(([k, v]) => (
                <div key={k} className="rounded-lg border border-zinc-800 bg-zinc-950/50 p-3">
                  <div className="text-xs font-semibold text-indigo-400 mb-1">{k}</div>
                  <div className="text-xs text-zinc-500">{v}</div>
                </div>
              ))}
            </div>
            <p className="text-xs text-zinc-500 italic">
              "No agent signature can move more value than the capability bounds, regardless of whether the agent key is compromised, jailbroken, manipulated, or acting maliciously." — Atlas Protocol Invariant
            </p>
          </Section>

          {/* Clawloan integration */}
          <Section title="The Proof of Concept: Clawloan × Atlas">
            <BulletList items={[
              "Clawloan offers unsecured micro-loans to AI agents based on credit reputation — no collateral required.",
              "Atlas adds the missing guarantee: the agent pre-commits earnings to a vault position and registers an envelope. Keeper fires at deadline, repays the loan, returns surplus. Agent never needs to be online.",
              "Each repayment generates a ZK-verifiable on-chain receipt. CreditVerifier upgrades the agent's tier (NEW → BRONZE → SILVER → GOLD → PLATINUM), unlocking larger loans.",
              "Current demo: $500 borrow → $1,000 earnings deposited → keeper triggers → $500 repaid → $500 surplus to vault → receipt recorded → tier upgrade.",
            ]} />
          </Section>

          {/* Tier progression */}
          <Section title="Credit Tier Economics">
            <div className="rounded-xl border border-zinc-800 overflow-hidden">
              <table className="w-full text-xs">
                <thead>
                  <tr className="border-b border-zinc-800 bg-zinc-950/50">
                    <th className="text-left px-4 py-2 text-zinc-500 font-medium">Tier</th>
                    <th className="text-left px-4 py-2 text-zinc-500 font-medium">Proven repayments</th>
                    <th className="text-right px-4 py-2 text-zinc-500 font-medium">Max borrow</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-800/50">
                  {[
                    ["NEW",      "0",   "$500"],
                    ["BRONZE",   "1+",  "$2,000"],
                    ["SILVER",   "6+",  "$10,000"],
                    ["GOLD",     "21+", "$50,000"],
                    ["PLATINUM", "50+", "$100,000"],
                  ].map(([tier, repay, max]) => (
                    <tr key={tier} className="px-4">
                      <td className="px-4 py-2 text-zinc-300 font-medium">{tier}</td>
                      <td className="px-4 py-2 text-zinc-500">{repay}</td>
                      <td className="px-4 py-2 text-right text-zinc-200 font-mono">{max}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Section>

          {/* Business model */}
          <Section title="Business Model">
            <BulletList items={[
              "Keeper fee: 0.1% of vault output paid to the triggering keeper per execution.",
              "Registration fee: optional flat fee per envelope registered (configurable at deployment).",
              "Solver fee: 0.1% of execution value for Atlas-native solvers.",
              "ZK credential layer (Phase 3): credit credentials issued per repayment, portable across DeFi protocols — recurring SaaS-like revenue from lenders verifying agent credit on-chain.",
            ]} />
          </Section>

          {/* Roadmap */}
          <Section title="Roadmap">
            <div className="space-y-2">
              {[
                ["Phase 1 — Now",      "Core protocol live on Anvil. Clawloan integration. Pre-audit."],
                ["Phase 2 — Q2 2026",  "External audit. Deploy to Arbitrum mainnet. UniswapV3 + Aave adapters."],
                ["Phase 3 — Q3 2026",  "ZK credit credentials via Noir/UltraHonk. Real Clawloan testnet integration."],
                ["Phase 4 — Q4 2026",  "Cross-chain execution. Sub-capability delegation chains. Keeper network launch."],
                ["Phase 5 — 2027",     "Aztec private execution migration (commitment model is ZK-native by design)."],
              ].map(([phase, desc]) => (
                <div key={phase} className="flex gap-3 text-xs">
                  <span className="text-indigo-400 font-medium shrink-0 w-32">{phase}</span>
                  <span className="text-zinc-500">{desc}</span>
                </div>
              ))}
            </div>
          </Section>

          {/* Technical credibility */}
          <Section title="Technical Credibility">
            <div className="grid grid-cols-2 gap-2">
              {[
                ["2 SSRN papers", "Full protocol spec + ZK layer published Feb 2026"],
                ["159 passing tests", "CapabilityKernel · EnvelopeRegistry · SingletonVault"],
                ["Audit prep doc", "Threat model, invariants, scope — ready for engagement"],
                ["Aztec migration path", "Commitment structure maps to notes — no redesign needed"],
              ].map(([label, sub]) => (
                <div key={label} className="rounded-lg bg-zinc-950/50 border border-zinc-800 p-3">
                  <div className="text-xs font-semibold text-zinc-200 mb-0.5">{label}</div>
                  <div className="text-xs text-zinc-600">{sub}</div>
                </div>
              ))}
            </div>
          </Section>

        </div>

        <div className="sticky bottom-0 bg-zinc-900 border-t border-zinc-800 px-8 py-4 rounded-b-3xl flex justify-end">
          <button onClick={onClose} className="px-5 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors">
            Back to demo →
          </button>
        </div>
      </div>
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div>
      <h3 className="text-sm font-semibold text-zinc-200 mb-3 pb-2 border-b border-zinc-800">{title}</h3>
      {children}
    </div>
  );
}

function BulletList({ items }: { items: string[] }) {
  return (
    <ul className="space-y-2">
      {items.map((item, i) => (
        <li key={i} className="flex items-start gap-2 text-sm text-zinc-400">
          <span className="text-indigo-400 mt-0.5 shrink-0">›</span>
          <span className="leading-relaxed">{item}</span>
        </li>
      ))}
    </ul>
  );
}
