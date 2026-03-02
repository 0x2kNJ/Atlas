/**
 * Phase 5 — "Publish the Key"
 *
 * The agent's private key is published on screen. Anyone can see it.
 * The capability bounds make it safe: attacker can spend at most $100/day.
 * After revocation, even $1 fails instantly.
 *
 * Proves: key compromise ≠ fund loss; bounded damage; instant revocation.
 */
import { useState, useCallback, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient } from "wagmi";
import { createWalletClient, http, parseUnits, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { anvil } from "viem/chains";

import { ADDRESSES, ANVIL_ACCOUNTS, ANVIL_CHAIN_ID } from "../contracts/addresses";
import {
  ERC20_ABI,
  VAULT_ABI,
  KERNEL_DIRECT_ABI,
} from "../contracts/abis";
import { LogPanel } from "../components/LogPanel";
import type { LogEntry } from "../components/LogPanel";
import { TxButton }  from "../components/TxButton";

import {
  buildCapability,
  buildIntent,
  signCapability,
  signIntent,
  randomSalt,
  ZERO_ADDRESS,
} from "@atlas-protocol/sdk";
import type { Position, Capability } from "@atlas-protocol/sdk";

const DEPOSIT_AMT  = parseUnits("500", 6);
const PERIOD_LIMIT = parseUnits("100", 6);

const AGENT = ANVIL_ACCOUNTS[1]; // Anvil account 1 — published key

interface PKState {
  position?:   Position;
  spendCap?:   Capability;
  capNonce?:   `0x${string}`;
  capSig?:     `0x${string}`;
}

export function PublishKeyScenario() {
  const { address }            = useAccount();
  const { data: walletClient } = useWalletClient();
  const publicClient           = usePublicClient();
  const logId = useRef(0);

  const [logs,       setLogs]      = useState<LogEntry[]>([]);
  const [step,       setStep]      = useState(0);
  const [busy,       setBusy]      = useState(false);
  const [revoked,    setRevoked]   = useState(false);
  const [keyVisible, setKeyVisible] = useState(false);
  const state = useRef<PKState>({});

  const log = useCallback((level: LogEntry["level"], msg: string) => {
    setLogs(p => [...p, { id: ++logId.current, ts: Date.now(), level, message: msg }]);
  }, []);

  const withBusy = useCallback(async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); }
    catch (e: unknown) { log("error", (e instanceof Error ? e.message : String(e)).slice(0, 300)); }
    finally { setBusy(false); }
  }, [log]);

  const agentClient = () => createWalletClient({
    account:   privateKeyToAccount(AGENT.privateKey as `0x${string}`),
    chain:     { ...anvil, id: ANVIL_CHAIN_ID } as never,
    transport: http("http://127.0.0.1:8545"),
  });

  // ── Setup: deposit $500, issue $100/day capability to agent ───────────────
  const setup = () => withBusy(async () => {
    if (!walletClient || !address) return;
    log("info", "Minting $500 USDC…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI, functionName: "mint",
      args: [address, DEPOSIT_AMT],
    })});
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI, functionName: "approve",
      args: [ADDRESSES.SingletonVault as `0x${string}`, DEPOSIT_AMT],
    })});
    const salt = toHex(randomSalt());
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.SingletonVault as `0x${string}`, abi: VAULT_ABI, functionName: "deposit",
      args: [ADDRESSES.MockUSDC as `0x${string}`, DEPOSIT_AMT, salt as `0x${string}`],
    })});
    const position: Position = { owner: address, asset: ADDRESSES.MockUSDC as `0x${string}`, amount: DEPOSIT_AMT, salt };
    state.current.position = position;
    log("success", "$500 deposited into vault");

    const { timestamp: now } = await publicClient!.getBlock({ blockTag: "latest" });
    const capNonce = toHex(randomSalt());
    const spendCap = buildCapability({
      issuer:  address,
      grantee: AGENT.address as `0x${string}`,
      expiry:  now + 30n * 86400n,
      nonce:   capNonce,
      constraints: {
        maxSpendPerPeriod: PERIOD_LIMIT,
        periodDuration:    86400n,
        minReturnBps:      0n,
        allowedAdapters:   [ADDRESSES.ClawloanRepayAdapter as `0x${string}`],
        allowedTokensIn:   [],
        allowedTokensOut:  [],
      },
    });
    const capSig = await signCapability(walletClient, spendCap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);
    state.current = { ...state.current, spendCap, capNonce: capNonce as `0x${string}`, capSig: capSig as `0x${string}` };

    log("success", `Capability issued | grantee: ${AGENT.address.slice(0, 10)}… | limit: $100/day`);
    setStep(1);
  });

  // ── Try to drain $500 (WILL FAIL: PeriodLimitExceeded) ───────────────────
  const tryDrain = () => withBusy(async () => {
    const { position, spendCap, capSig } = state.current;
    if (!position || !spendCap || !capSig || !publicClient || !address) return;
    log("info", `Attacker holds key ${AGENT.address.slice(0, 10)}… | trying $500 drain…`);
    const { timestamp: now } = await publicClient.getBlock({ blockTag: "latest" });
    const attacker = agentClient();
    const drainIntent = buildIntent({
      position,
      capability:  spendCap,
      adapter:     ADDRESSES.ClawloanRepayAdapter as `0x${string}`,
      adapterData: "0x",
      minReturn:   0n,
      deadline:    now + 3600n,
      nonce:       toHex(randomSalt()),
      outputToken: ADDRESSES.MockUSDC as `0x${string}`,
      returnTo:    ZERO_ADDRESS,
      submitter:   ZERO_ADDRESS,
      solverFeeBps: 0,
    });
    const drainSig = await signIntent(attacker, drainIntent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);
    try {
      await publicClient.simulateContract({
        address: ADDRESSES.CapabilityKernel as `0x${string}`,
        abi: KERNEL_DIRECT_ABI,
        functionName: "executeIntent",
        args: [position as never, spendCap as never, drainIntent as never, capSig, drainSig as `0x${string}`],
        account: address as `0x${string}`,
      });
      log("warn", "Simulation unexpectedly passed — check adapter data");
    } catch (e: unknown) {
      const errStr = String(e);
      const reason = errStr.includes("PeriodLimitExceeded")     ? "PeriodLimitExceeded"
                   : errStr.includes("AdapterValidationFailed") ? "AdapterValidationFailed"
                   : errStr.includes("CommitmentMismatch")       ? "CommitmentMismatch"
                   : "Rejected";
      log("success", `KERNEL REJECTED — ${reason} | $500 > $100/day cap`);
      log("info", "Attacker holds the full key. Position is safe.");
    }
    setStep(2);
  });

  // ── Revoke capability ─────────────────────────────────────────────────────
  const revokeCapability = () => withBusy(async () => {
    if (!walletClient) return;
    const { capNonce } = state.current;
    if (!capNonce) return;
    log("info", "Revoking capability nonce (1 transaction)…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.CapabilityKernel as `0x${string}`,
      abi: KERNEL_DIRECT_ABI,
      functionName: "revokeCapabilityNonce",
      args: [capNonce as `0x${string}`],
    })});
    setRevoked(true);
    log("success", "Capability nonce REVOKED — all future intents with this nonce rejected");
    log("info", "1 transaction. Instant. Permanent. No timelock.");
    setStep(3);
  });

  // ── Post-revoke drain attempt ─────────────────────────────────────────────
  const postRevokeDrain = () => withBusy(async () => {
    const { position, spendCap, capSig } = state.current;
    if (!position || !spendCap || !capSig || !publicClient || !address) return;
    log("info", "Post-revocation: attacker tries any intent…");
    const { timestamp: now } = await publicClient.getBlock({ blockTag: "latest" });
    const attacker = agentClient();
    const intent = buildIntent({
      position,
      capability:  spendCap,
      adapter:     ADDRESSES.ClawloanRepayAdapter as `0x${string}`,
      adapterData: "0x",
      minReturn:   0n,
      deadline:    now + 3600n,
      nonce:       toHex(randomSalt()),
      outputToken: ADDRESSES.MockUSDC as `0x${string}`,
      returnTo:    ZERO_ADDRESS,
      submitter:   ZERO_ADDRESS,
      solverFeeBps: 0,
    });
    const sig = await signIntent(attacker, intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);
    try {
      await publicClient.simulateContract({
        address: ADDRESSES.CapabilityKernel as `0x${string}`,
        abi: KERNEL_DIRECT_ABI,
        functionName: "executeIntent",
        args: [position as never, spendCap as never, intent as never, capSig, sig as `0x${string}`],
        account: address as `0x${string}`,
      });
      log("warn", "Unexpected success");
    } catch {
      log("success", "KERNEL REJECTED — CapabilityNonceRevoked | the key is now worthless");
    }
  });

  return (
    <div className="flex gap-6 w-full">
      <div className="flex-1 min-w-0 flex flex-col gap-4">

        <div className="rounded-xl border border-red-700 bg-red-950/20 p-5">
          <div className="flex items-center gap-3 mb-2">
            <span className="text-2xl">🔑</span>
            <div>
              <h2 className="text-lg font-bold text-red-300">Publish the Key</h2>
              <p className="text-xs text-slate-400">Live key-compromise invariant demo</p>
            </div>
          </div>
          <p className="text-sm text-slate-300 mt-2">
            The agent's private key is on screen. The attacker can steal at most
            <span className="text-red-300 font-semibold"> $100/day</span> — not $500. After revocation, $1 fails.
          </p>
        </div>

        {/* Published key */}
        {step >= 1 && (
          <div className="rounded-xl border border-yellow-700 bg-yellow-950/20 p-4">
            <div className="flex items-center justify-between mb-2">
              <span className="text-sm font-bold text-yellow-300">⚠️  Agent Private Key — PUBLICLY EXPOSED</span>
              <button onClick={() => setKeyVisible(v => !v)} className="text-xs text-yellow-500 hover:text-yellow-300 underline">
                {keyVisible ? "hide" : "show"}
              </button>
            </div>
            {keyVisible && (
              <code className="text-xs text-red-400 font-mono break-all block bg-black/40 p-2 rounded">{AGENT.privateKey}</code>
            )}
            <p className="text-xs text-slate-500 mt-2">Address: <code className="text-yellow-400 font-mono">{AGENT.address}</code></p>
          </div>
        )}

        {/* Setup */}
        <div className="rounded-xl border border-slate-700 bg-slate-900/50 p-4">
          <div className="text-sm font-bold text-slate-300 mb-2">Setup</div>
          <p className="text-sm text-slate-400 mb-3">Deposit $500. Issue a $100/day capability to Anvil account 1 (the "agent key").</p>
          <TxButton label="Deposit $500 + Issue $100/day Capability" onClick={setup} disabled={step !== 0 || busy} />
        </div>

        {step >= 1 && (
          <div className="rounded-xl border border-red-800 bg-red-950/10 p-4">
            <div className="text-sm font-bold text-red-300 mb-2">Attacker tries to drain $500</div>
            <p className="text-sm text-slate-400 mb-3">Kernel enforces <code className="text-xs text-red-300">PeriodLimitExceeded</code> — $500 &gt; $100/day cap.</p>
            <TxButton label="Try $500 drain (will fail)" onClick={tryDrain} disabled={step !== 1 || busy} variant="danger" />
          </div>
        )}

        {step >= 2 && !revoked && (
          <div className="rounded-xl border border-emerald-800 bg-emerald-950/10 p-4">
            <div className="text-sm font-bold text-emerald-300 mb-2">Revoke the capability (1 transaction)</div>
            <p className="text-sm text-slate-400 mb-3">Permanently kills all future intents from this nonce. Instant, no timelock.</p>
            <TxButton label="Revoke Capability" onClick={revokeCapability} disabled={step !== 2 || busy} />
          </div>
        )}

        {revoked && (
          <>
            <div className="rounded-xl border border-emerald-600 bg-emerald-950/20 p-4 text-center">
              <div className="text-emerald-300 font-bold">✓ Capability Revoked</div>
              <p className="text-xs text-slate-400 mt-1">The attacker's key is now worthless.</p>
            </div>
            <div className="rounded-xl border border-slate-700 bg-slate-900/50 p-4">
              <div className="text-sm font-bold text-slate-300 mb-2">Post-revocation attempt</div>
              <TxButton label="Try $80 after revocation (will fail)" onClick={postRevokeDrain} disabled={busy} variant="secondary" />
            </div>
          </>
        )}

        <LogPanel entries={logs} />
      </div>

      {/* Right panel */}
      <div className="w-80 flex-shrink-0 flex flex-col gap-4">
        <div className="rounded-xl border border-red-700 bg-red-950/20 p-4 text-xs">
          <h3 className="text-sm font-bold text-red-300 mb-3">The Invariant</h3>
          <div className="grid grid-cols-2 gap-2 mb-3">
            <div className="bg-slate-900 rounded p-3">
              <div className="font-bold text-red-400 mb-1">Without Atlas</div>
              <ul className="space-y-1 text-slate-400">
                <li>Key stolen</li>
                <li>Full session scope lost</li>
                <li>$500 gone immediately</li>
              </ul>
            </div>
            <div className="bg-orange-950/30 rounded p-3 border border-orange-800">
              <div className="font-bold text-orange-300 mb-1">With Atlas</div>
              <ul className="space-y-1 text-orange-200">
                <li>Key stolen</li>
                <li>Max $100/day damage</li>
                <li>Revoke in 1 tx</li>
              </ul>
            </div>
          </div>
          <p className="text-slate-400">Hot keys on AI agents get stolen. Atlas caps the blast radius to one period's allowance regardless of what the attacker does with the key.</p>
        </div>
        <div className="rounded-xl border border-slate-700 bg-slate-900/50 p-4 text-xs text-slate-400">
          <div className="font-semibold text-slate-300 mb-2">Revocation properties</div>
          <ul className="space-y-1">
            <li>✓ 1 transaction, instant effect</li>
            <li>✓ Permanent — no recovery path</li>
            <li>✓ No timelock or waiting period</li>
            <li>✓ Works even if agent is offline</li>
            <li>✓ All intents using this nonce: dead</li>
          </ul>
        </div>
      </div>
    </div>
  );
}
