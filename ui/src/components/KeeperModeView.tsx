import { useState, useEffect, useCallback } from "react";
import { useAccount, useWalletClient, usePublicClient } from "wagmi";
import { useConnect, useDisconnect } from "wagmi";
import { injected } from "wagmi/connectors";
import { toHex } from "viem";
import { REGISTRY_ABI, VAULT_ABI } from "../contracts/abis";
import { ADDRESSES } from "../contracts/addresses";
import { TxButton } from "./TxButton";

// ─── BigInt-safe serialization ────────────────────────────────────────────────
function bigintReviver(_: string, v: unknown) {
  if (v && typeof v === "object" && "__bigint" in (v as object)) {
    return BigInt((v as { __bigint: string }).__bigint);
  }
  return v;
}

export function ENVELOPE_STORAGE_KEY() { return "atlas_pending_envelopes"; }

export interface StoredEnvelope {
  envelopeHash:   string;
  capabilityHash: string;
  positionHash:   string;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  conditions:     any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  position:       any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  intent:         any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  spendCap:       any;
  capSig:         string;
  intentSig:      string;
  loanDeadline:   bigint;
  agentAddress:   string;
  registeredAt:   number;
  triggered:      boolean;
  triggerTx?:     string;
}

function loadEnvelopes(): StoredEnvelope[] {
  try {
    const raw = localStorage.getItem(ENVELOPE_STORAGE_KEY());
    if (!raw) return [];
    return JSON.parse(raw, bigintReviver) as StoredEnvelope[];
  } catch {
    return [];
  }
}

function saveEnvelopes(envelopes: StoredEnvelope[]) {
  localStorage.setItem(
    ENVELOPE_STORAGE_KEY(),
    JSON.stringify(envelopes, (_, v) => typeof v === "bigint" ? { __bigint: v.toString() } : v)
  );
}

// ─── Keeper Mode View ─────────────────────────────────────────────────────────
export function KeeperModeView() {
  const { address, isConnected } = useAccount();
  const { data: walletClient }   = useWalletClient();
  const publicClient             = usePublicClient();
  const { connect }              = useConnect();
  const { disconnect }           = useDisconnect();

  const [envelopes,  setEnvelopes]  = useState<StoredEnvelope[]>([]);
  const [busy,       setBusy]       = useState<Record<string, boolean>>({});
  const [logs,       setLogs]       = useState<string[]>([]);
  const [deadlinesMet, setDeadlinesMet] = useState<Record<string, boolean>>({});

  const log = useCallback((msg: string) => {
    setLogs(prev => [`[${new Date().toLocaleTimeString()}] ${msg}`, ...prev]);
  }, []);

  // Load from localStorage
  useEffect(() => {
    setEnvelopes(loadEnvelopes());
    const listener = () => setEnvelopes(loadEnvelopes());
    window.addEventListener("storage", listener);
    return () => window.removeEventListener("storage", listener);
  }, []);

  // Refresh
  function refresh() {
    setEnvelopes(loadEnvelopes());
    log("Refreshed envelope list from storage.");
  }

  // Check conditions live
  useEffect(() => {
    if (!publicClient) return;
    let cancelled = false;
    async function checkConditions() {
      const active = envelopes.filter(e => !e.triggered);
      const results: Record<string, boolean> = {};
      for (const env of active) {
        try {
          const block = await publicClient!.getBlock({ blockTag: "latest" });
          results[env.envelopeHash] = block.timestamp > env.loanDeadline;
        } catch {
          results[env.envelopeHash] = false;
        }
      }
      if (!cancelled) setDeadlinesMet(results);
    }
    checkConditions();
    const id = setInterval(checkConditions, 3000);
    return () => { cancelled = true; clearInterval(id); };
  }, [envelopes, publicClient]);

  async function trigger(env: StoredEnvelope) {
    const key = env.envelopeHash;
    setBusy(b => ({ ...b, [key]: true }));
    try {
      if (!walletClient || !address) throw new Error("Connect wallet first");

      // Time-warp past deadline if needed
      const block = await publicClient!.getBlock({ blockTag: "latest" });
      const minTs = block.timestamp + 1n;
      const targetTs = env.loanDeadline + 1n > minTs ? env.loanDeadline + 1n : minTs;
      await publicClient!.request({
        method: "evm_setNextBlockTimestamp" as never,
        params: [toHex(targetTs)] as never,
      });
      await publicClient!.request({ method: "evm_mine" as never, params: [] as never });
      log(`Warped to ${new Date(Number(targetTs) * 1000).toLocaleString()} — condition met`);

      // Check envelope active
      const isActive = await publicClient!.readContract({
        address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
        abi: REGISTRY_ABI,
        functionName: "isActive",
        args: [env.envelopeHash as `0x${string}`],
      }) as boolean;
      if (!isActive) throw new Error("Envelope already triggered or not found on-chain. Agent may need to re-register.");

      // Check position still exists
      const posExists = await publicClient!.readContract({
        address: ADDRESSES.SingletonVault as `0x${string}`,
        abi: VAULT_ABI,
        functionName: "positionExists",
        args: [env.positionHash as `0x${string}`],
      }) as boolean;
      if (!posExists) throw new Error("Position already spent — envelope may have already been triggered.");

      log(`Triggering envelope ${env.envelopeHash.slice(0, 14)}…`);

      // Simulate first
      await publicClient!.simulateContract({
        address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
        abi: REGISTRY_ABI,
        functionName: "trigger",
        args: [
          env.envelopeHash as `0x${string}`,
          env.conditions,
          env.position,
          env.intent,
          env.spendCap,
          env.capSig as `0x${string}`,
          env.intentSig as `0x${string}`,
        ],
        account: address,
      });

      const hash = await walletClient.writeContract({
        address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
        abi: REGISTRY_ABI,
        functionName: "trigger",
        args: [
          env.envelopeHash as `0x${string}`,
          env.conditions,
          env.position,
          env.intent,
          env.spendCap,
          env.capSig as `0x${string}`,
          env.intentSig as `0x${string}`,
        ],
      });
      const receipt = await publicClient!.waitForTransactionReceipt({ hash });
      if (receipt.status === "reverted") throw new Error(`Trigger TX reverted: ${hash}`);

      log(`Loan repaid by keeper! tx ${hash.slice(0, 10)}…`);
      log(`Keeper earned ~${(Number(env.position.amount) * 10 / 10000 / 1e6).toFixed(3)} USDC (0.1% fee)`);

      // Mark triggered in storage
      const updated = loadEnvelopes().map(e =>
        e.envelopeHash === env.envelopeHash ? { ...e, triggered: true, triggerTx: hash } : e
      );
      saveEnvelopes(updated);
      setEnvelopes(updated);
    } catch (e: unknown) {
      log(`ERROR: ${e instanceof Error ? e.message.slice(0, 200) : String(e)}`);
    } finally {
      setBusy(b => ({ ...b, [key]: false }));
    }
  }

  function clearAll() {
    localStorage.removeItem(ENVELOPE_STORAGE_KEY());
    setEnvelopes([]);
    log("Cleared all stored envelopes.");
  }

  const active   = envelopes.filter(e => !e.triggered);
  const history  = envelopes.filter(e => e.triggered);

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100 flex flex-col">
      {/* Header */}
      <header className="border-b border-zinc-800 px-6 py-4 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <span className="text-2xl">⚡</span>
          <div>
            <h1 className="text-lg font-bold tracking-tight text-emerald-300">
              Keeper Mode
            </h1>
            <p className="text-xs text-zinc-500 mt-0.5">
              Trigger pre-committed Atlas envelopes — no agent coordination needed
            </p>
          </div>
        </div>
        <div className="flex items-center gap-3 text-sm">
          <a href="/" className="text-xs text-zinc-500 hover:text-zinc-300 transition-colors">← Agent Mode</a>
          <span className="text-zinc-700">|</span>
          {isConnected ? (
            <>
              <span className="text-zinc-400 font-mono text-xs">{address?.slice(0, 6)}…{address?.slice(-4)}</span>
              <button onClick={() => disconnect()} className="text-zinc-600 hover:text-zinc-300 text-xs transition-colors">disconnect</button>
            </>
          ) : (
            <button
              onClick={() => connect({ connector: injected() })}
              className="px-4 py-1.5 rounded-lg bg-emerald-700 hover:bg-emerald-600 text-white text-sm font-medium transition-colors"
            >
              Connect Keeper Wallet
            </button>
          )}
        </div>
      </header>

      <main className="flex-1 p-6 max-w-5xl mx-auto w-full grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Left: envelope list */}
        <div className="lg:col-span-2 flex flex-col gap-4">

          {/* Explainer */}
          <div className="rounded-2xl border border-emerald-800/30 bg-emerald-950/20 p-5">
            <p className="text-sm font-medium text-emerald-300 mb-1">How keeper mode works</p>
            <p className="text-xs text-zinc-500 leading-relaxed">
              The agent deposited earnings into Atlas, pre-signed a repayment intent, and registered an
              envelope on-chain. The agent is now offline. You — the keeper — can call{" "}
              <span className="font-mono text-zinc-400">registry.trigger()</span> once the condition
              (block.timestamp &gt; loanDeadline) is true. The loan repays automatically.
              You earn a keeper fee for the execution.
            </p>
            <div className="flex items-center gap-2 mt-2 text-xs text-zinc-600">
              <span className="text-emerald-400">Agent offline</span>
              <span>→</span>
              <span className="text-emerald-400">Deadline passes</span>
              <span>→</span>
              <span className="text-emerald-400">Keeper triggers</span>
              <span>→</span>
              <span className="text-zinc-400">Loan repaid · receipt on-chain · fee earned</span>
            </div>
          </div>

          {/* Active envelopes */}
          <div>
            <div className="flex items-center justify-between mb-3">
              <h2 className="text-sm font-semibold text-zinc-300">
                Pending Envelopes ({active.length})
              </h2>
              <div className="flex gap-2">
                <button onClick={refresh} className="text-xs text-zinc-500 hover:text-zinc-300 transition-colors px-2 py-1 rounded bg-zinc-800">refresh</button>
                {envelopes.length > 0 && (
                  <button onClick={clearAll} className="text-xs text-red-600 hover:text-red-400 transition-colors px-2 py-1 rounded bg-zinc-800">clear all</button>
                )}
              </div>
            </div>

            {active.length === 0 && (
              <div className="rounded-2xl border border-zinc-800 bg-zinc-900/50 p-8 text-center">
                <p className="text-zinc-500 text-sm mb-1">No pending envelopes</p>
                <p className="text-xs text-zinc-700">
                  Go to <a href="/" className="text-indigo-400 hover:underline">Agent Mode</a>, run through steps 1–3 (borrow → deposit → register), then come back here.
                </p>
              </div>
            )}

            <div className="space-y-3">
              {active.map(env => (
                <EnvelopeCard
                  key={env.envelopeHash}
                  env={env}
                  conditionMet={deadlinesMet[env.envelopeHash] ?? false}
                  busy={!!busy[env.envelopeHash]}
                  onTrigger={() => trigger(env)}
                  keeperAddress={address}
                />
              ))}
            </div>
          </div>

          {/* History */}
          {history.length > 0 && (
            <div>
              <h2 className="text-sm font-semibold text-zinc-500 mb-3">Triggered ({history.length})</h2>
              <div className="space-y-2">
                {history.map(env => (
                  <div key={env.envelopeHash} className="rounded-xl border border-emerald-800/30 bg-emerald-950/20 px-4 py-3 flex items-center justify-between text-xs">
                    <div>
                      <span className="text-emerald-400 font-mono">{env.envelopeHash.slice(0, 18)}…</span>
                      <span className="text-zinc-600 ml-2">agent: {env.agentAddress.slice(0, 10)}…</span>
                    </div>
                    <div className="flex items-center gap-2">
                      <span className="text-emerald-400">triggered ✓</span>
                      {env.triggerTx && (
                        <span className="text-zinc-600 font-mono">{env.triggerTx.slice(0, 10)}…</span>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Right: log */}
        <div>
          <h2 className="text-sm font-semibold text-zinc-300 mb-2">Keeper Log</h2>
          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-4 font-mono text-xs space-y-1 max-h-[500px] overflow-y-auto">
            {logs.length === 0 && <p className="text-zinc-600">No activity yet.</p>}
            {logs.map((l, i) => (
              <div key={i} className={`${l.includes("ERROR") ? "text-red-400" : l.includes("Loan repaid") || l.includes("Keeper earned") ? "text-emerald-400" : "text-zinc-400"}`}>
                {l}
              </div>
            ))}
          </div>

          {/* Keeper economics */}
          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-4 mt-4">
            <h3 className="text-xs font-semibold text-zinc-400 mb-3">Keeper Economics</h3>
            <div className="space-y-2 text-xs">
              <Row label="Fee rate" value="0.1% of vault position" />
              <Row label="$1,000 deposit" value="~$1.00 keeper fee" />
              <Row label="Gas cost" value="~0.0001 ETH (local)" />
              <Row label="Net per trigger" value="~$0.99 on $1,000 cycle" />
            </div>
            <p className="text-xs text-zinc-700 mt-3 leading-relaxed">
              Any address can keep envelopes. At scale, a dedicated keeper network competes for fees, ensuring timely execution.
            </p>
          </div>
        </div>
      </main>
    </div>
  );
}

function EnvelopeCard({
  env, conditionMet, busy, onTrigger, keeperAddress,
}: {
  env: StoredEnvelope;
  conditionMet: boolean;
  busy: boolean;
  onTrigger: () => void;
  keeperAddress?: string;
}) {
  const deadline = new Date(Number(env.loanDeadline) * 1000);
  const registered = new Date(env.registeredAt);

  return (
    <div className={`rounded-2xl border p-5 transition-all ${conditionMet ? "border-emerald-700 bg-emerald-950/20" : "border-zinc-800 bg-zinc-900"}`}>
      <div className="flex items-start justify-between mb-3">
        <div>
          <div className="text-xs font-mono text-zinc-300">{env.envelopeHash.slice(0, 20)}…</div>
          <div className="text-xs text-zinc-600 mt-0.5">
            Agent: {env.agentAddress.slice(0, 12)}… · Registered: {registered.toLocaleTimeString()}
          </div>
        </div>
        <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${conditionMet ? "bg-emerald-900/60 text-emerald-300" : "bg-zinc-800 text-zinc-500"}`}>
          {conditionMet ? "condition met ✓" : "waiting…"}
        </span>
      </div>

      <div className="grid grid-cols-2 gap-3 mb-4 text-xs">
        <Detail label="Condition" value="block.timestamp > deadline" />
        <Detail label="Deadline" value={deadline.toLocaleString()} />
        <Detail label="Vault position" value={`${(Number(env.position?.amount ?? 0n) / 1e6).toFixed(0)} USDC`} />
        <Detail
          label="Keeper fee"
          value={`~${(Number(env.position?.amount ?? 0n) * 10 / 10000 / 1e6).toFixed(3)} USDC`}
          highlight
        />
      </div>

      <div className="flex items-center gap-3">
        <TxButton
          label={conditionMet ? "⚡ Trigger Envelope" : "Trigger (warps time)"}
          onClick={onTrigger}
          loading={busy}
          disabled={!keeperAddress}
          variant="keeper"
        />
        {!keeperAddress && <span className="text-xs text-zinc-600">Connect wallet to trigger</span>}
        {conditionMet && <span className="text-xs text-emerald-500">You will earn ~{(Number(env.position?.amount ?? 0n) * 10 / 10000 / 1e6).toFixed(3)} USDC</span>}
      </div>
    </div>
  );
}

function Detail({ label, value, highlight }: { label: string; value: string; highlight?: boolean }) {
  return (
    <div>
      <div className="text-zinc-600 text-xs mb-0.5">{label}</div>
      <div className={`text-xs ${highlight ? "text-emerald-400 font-medium" : "text-zinc-300"}`}>{value}</div>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between">
      <span className="text-zinc-500">{label}</span>
      <span className="text-zinc-300">{value}</span>
    </div>
  );
}
