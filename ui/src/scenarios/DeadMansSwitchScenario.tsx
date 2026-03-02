/**
 * Phase 2 — Dead Man's Switch Scenario
 *
 * Narrative: An AI agent manages a $2,000 USDC treasury on behalf of a DAO.
 * The agent pre-commits a failsafe envelope: "If I stop checking in for 24 hours,
 * transfer all funds to the DAO multisig." Atlas enforces this regardless of
 * whether the agent is online, its key is compromised, or it crashes.
 *
 * The "check-in" is just cancel + re-register with a fresh deadline. No check-in = switch fires.
 *
 * Steps:
 *  0  Mint treasury USDC
 *  1  Set up beneficiary (DAO multisig address)
 *  2  Deposit treasury into Atlas vault
 *  3  Register Dead Man's Switch envelope (24-hour heartbeat window)
 *  4a Check-in  — cancel envelope + re-register with fresh deadline (agent still alive)
 *  4b Go Dark   — skip check-in and let the switch fire
 *  5  Keeper triggers switch → funds flow to DAO beneficiary
 */
import { useState, useCallback, useEffect, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient, useBalance } from "wagmi";
import { encodeAbiParameters, toHex, parseUnits } from "viem";

import { ADDRESSES, ANVIL_CHAIN_ID } from "../contracts/addresses";
import {
  ERC20_ABI,
  VAULT_ABI,
  REGISTRY_ABI,
} from "../contracts/abis";
import { StepCard }  from "../components/StepCard";
import { TxButton }  from "../components/TxButton";
import { LogPanel }  from "../components/LogPanel";
import type { LogEntry } from "../components/LogPanel";

import {
  buildCapability,
  buildManageCapability,
  buildIntent,
  buildEnvelope,
  signCapability,
  signManageCapability,
  signIntent,
  randomSalt,
  hashPosition,
  hashCapability,
  hashEnvelope,
  ZERO_ADDRESS,
  ComparisonOp,
  LogicOp,
} from "@atlas-protocol/sdk";
import type { Position, Capability, Intent, Conditions } from "@atlas-protocol/sdk";

// ─── Constants ────────────────────────────────────────────────────────────────
const TREASURY_AMT  = parseUnits("2000", 6);  // $2,000 USDC agent treasury
const HEARTBEAT_SEC = 24 * 60 * 60;           // 24-hour check-in window

// Anvil account 1 as "DAO multisig beneficiary"
const DAO_BENEFICIARY = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

function bigintReplacer(_: string, v: unknown) {
  return typeof v === "bigint" ? { __bigint: v.toString() } : v;
}
const DMS_KEY = "atlas_dms_envelopes";

interface DmsState {
  positionHash?:   `0x${string}`;
  envelopeHash?:   `0x${string}`;
  capabilityHash?: `0x${string}`;
  position?:       Position;
  spendCap?:       Capability;
  intent?:         Intent;
  capSig?:         `0x${string}`;
  intentSig?:      `0x${string}`;
  conditions?:     Conditions;
  deadline?:       bigint;
  posSalt?:        `0x${string}`;
  beneficiary?:    string;
  checkInCount?:   number;
}

export function DeadMansSwitchScenario() {
  const { address, isConnected }  = useAccount();
  const { data: walletClient }    = useWalletClient();
  const publicClient              = usePublicClient();

  const [demo,  setDemo]  = useState<DmsState>({});
  const [logs,  setLogs]  = useState<LogEntry[]>([]);
  const [busy,  setBusy]  = useState<Record<string, boolean>>({});
  const [armed, setArmed] = useState(false);
  const [fired, setFired] = useState(false);
  const [beneficiaryBalance, setBeneficiaryBalance] = useState<bigint>(0n);
  const logId = useRef(0);

  const log = useCallback((level: LogEntry["level"], message: string) => {
    setLogs(prev => [...prev, { id: ++logId.current, ts: Date.now(), level, message }]);
  }, []);

  const withBusy = useCallback(async (key: string, fn: () => Promise<void>) => {
    setBusy(b => ({ ...b, [key]: true }));
    try { await fn(); }
    catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error("[DMS]", e);
      log("error", msg.slice(0, 300));
    }
    finally { setBusy(b => ({ ...b, [key]: false })); }
  }, [log]);

  // Auto-airdrop ETH on connect
  const { data: ethBalance } = useBalance({ address });
  const airdropped = useRef<string | null>(null);
  useEffect(() => {
    if (!address || !isConnected) return;
    if (airdropped.current === address) return;
    if (ethBalance && ethBalance.value >= parseUnits("1", 18)) return;
    airdropped.current = address;
    fetch("http://127.0.0.1:8545", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "anvil_setBalance", params: [address, toHex(parseUnits("10", 18))] }),
    }).catch(() => {});
  }, [address, isConnected, ethBalance]);

  // Poll beneficiary balance after firing
  useEffect(() => {
    if (!fired || !publicClient) return;
    const poll = async () => {
      const bal = await publicClient.readContract({
        address: ADDRESSES.MockUSDC as `0x${string}`,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: [DAO_BENEFICIARY as `0x${string}`],
      }) as bigint;
      setBeneficiaryBalance(bal);
    };
    poll();
    const t = setInterval(poll, 3000);
    return () => clearInterval(t);
  }, [fired, publicClient]);

  // ── Step 0: Mint USDC treasury ──────────────────────────────────────────────
  async function mintTreasury() {
    await withBusy("mint", async () => {
      if (!walletClient || !address) throw new Error("wallet not connected");
      log("info", `Minting $${Number(TREASURY_AMT) / 1e6} USDC agent treasury…`);
      const hash = await walletClient.writeContract({
        address: ADDRESSES.MockUSDC as `0x${string}`,
        abi: ERC20_ABI,
        functionName: "mint",
        args: [address, TREASURY_AMT],
      });
      await publicClient!.waitForTransactionReceipt({ hash });
      log("success", `Treasury minted — $${Number(TREASURY_AMT) / 1e6} USDC ready`);
    });
  }

  // ── Step 2: Approve + deposit into vault ───────────────────────────────────
  async function depositTreasury() {
    await withBusy("deposit", async () => {
      if (!walletClient || !address) throw new Error("wallet not connected");

      const balance = await publicClient!.readContract({
        address: ADDRESSES.MockUSDC as `0x${string}`,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: [address],
      }) as bigint;
      if (balance < TREASURY_AMT) throw new Error(`Need $${Number(TREASURY_AMT) / 1e6} USDC — mint first`);

      const allowance = await publicClient!.readContract({
        address: ADDRESSES.MockUSDC as `0x${string}`,
        abi: ERC20_ABI,
        functionName: "allowance",
        args: [address, ADDRESSES.SingletonVault as `0x${string}`],
      }) as bigint;

      if (allowance < TREASURY_AMT) {
        const approveHash = await walletClient.writeContract({
          address: ADDRESSES.MockUSDC as `0x${string}`,
          abi: ERC20_ABI,
          functionName: "approve",
          args: [ADDRESSES.SingletonVault as `0x${string}`, BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")],
        });
        await publicClient!.waitForTransactionReceipt({ hash: approveHash });
        log("success", "Vault approved for USDC");
      }

      const salt = randomSalt();
      log("info", `Depositing $${Number(TREASURY_AMT) / 1e6} USDC treasury into Atlas vault…`);

      const hash = await walletClient.writeContract({
        address: ADDRESSES.SingletonVault as `0x${string}`,
        abi: VAULT_ABI,
        functionName: "deposit",
        args: [ADDRESSES.MockUSDC as `0x${string}`, TREASURY_AMT, salt],
      });
      const receipt = await publicClient!.waitForTransactionReceipt({ hash });
      if (receipt.status === "reverted") throw new Error(`Deposit TX reverted: ${hash}`);

      const pos: Position = { owner: address, asset: ADDRESSES.MockUSDC as `0x${string}`, amount: TREASURY_AMT, salt };
      const posHash = hashPosition(pos);

      log("success", `$${Number(TREASURY_AMT) / 1e6} USDC locked in vault — position ${posHash.slice(0, 10)}…`);
      setDemo(d => ({ ...d, positionHash: posHash, position: pos, posSalt: salt, beneficiary: DAO_BENEFICIARY }));
    });
  }

  // ── Step 3: Register Dead Man's Switch envelope ────────────────────────────
  async function registerDms() {
    await withBusy("register", async () => {
      if (!walletClient || !address || !demo.position || !demo.positionHash)
        throw new Error("complete step 2 first");

      // Use on-chain block.timestamp as base — Anvil may have been time-warped
      // from a previous scenario run, making Date.now() stale relative to chain time.
      const latestBlock = await publicClient!.getBlock({ blockTag: "latest" });
      const now      = latestBlock.timestamp;
      const deadline = now + BigInt(HEARTBEAT_SEC);
      const capExpiry = now + BigInt(30 * 24 * 60 * 60);

      const capNonce    = randomSalt();
      const intentNonce = randomSalt();
      const manageNonce = randomSalt();

      // Beneficiary address encoded in adapter data — signed over by agent in EIP-712 intent hash.
      const adapterData = encodeAbiParameters(
        [{ type: "address" }],
        [DAO_BENEFICIARY as `0x${string}`]
      );

      const spendCap = buildCapability({
        issuer:   address,
        grantee:  address,
        expiry:   capExpiry,
        nonce:    capNonce,
        constraints: {
          maxSpendPerPeriod: 0n,
          periodDuration:    0n,
          minReturnBps:      0n,
          allowedAdapters:   [ADDRESSES.DirectTransferAdapter as `0x${string}`],
          allowedTokensIn:   [ADDRESSES.MockUSDC as `0x${string}`],
          allowedTokensOut:  [ADDRESSES.MockUSDC as `0x${string}`],
        },
      });

      const intent = buildIntent({
        position:     demo.position,
        capability:   spendCap,
        adapter:      ADDRESSES.DirectTransferAdapter as `0x${string}`,
        adapterData,
        minReturn:    1n,   // 1 dust unit (all but 1 goes to DAO)
        deadline:     capExpiry,
        nonce:        intentNonce,
        outputToken:  ADDRESSES.MockUSDC as `0x${string}`,
        returnTo:     ZERO_ADDRESS,
        submitter:    ADDRESSES.EnvelopeRegistry as `0x${string}`,
        solverFeeBps: 0,
      });

      const manageCap = buildManageCapability({
        issuer:  address,
        grantee: address,
        expiry:  capExpiry,
        nonce:   manageNonce,
      });

      const conditions: Conditions = {
        priceOracle:           ADDRESSES.MockTimestampOracle as `0x${string}`,
        baseToken:             ZERO_ADDRESS,
        quoteToken:            ZERO_ADDRESS,
        triggerPrice:          deadline,
        op:                    ComparisonOp.GREATER_THAN,
        secondaryOracle:       ZERO_ADDRESS,
        secondaryTriggerPrice: 0n,
        secondaryOp:           ComparisonOp.LESS_THAN,
        logicOp:               LogicOp.AND,
      };

      const envelope = buildEnvelope({
        position:          demo.position,
        conditions,
        intent,
        manageCapability:  manageCap,
        expiry:            deadline + BigInt(48 * 60 * 60),
        keeperRewardBps:   10,
        minKeeperRewardWei: 0n,
      });

      log("info", "Signing capability (1/3)…");
      const capSig = await signCapability(walletClient, spendCap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

      log("info", "Signing intent (2/3)…");
      const intentSig = await signIntent(walletClient, intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

      log("info", "Signing manage capability (3/3)…");
      const manageCapSig = await signManageCapability(walletClient, manageCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

      log("info", "Registering DMS envelope on-chain…");

      try {
        await publicClient!.simulateContract({
          address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
          abi: REGISTRY_ABI,
          functionName: "register",
          args: [envelope as never, manageCap as never, manageCapSig, demo.position as never],
          account: address,
        });
      } catch (simErr: unknown) {
        const msg = simErr instanceof Error ? simErr.message : String(simErr);
        throw new Error(`Register sim failed: ${msg.slice(0, 300)}`);
      }

      const hash = await walletClient.writeContract({
        address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
        abi: REGISTRY_ABI,
        functionName: "register",
        args: [envelope as never, manageCap as never, manageCapSig, demo.position as never],
      });
      const regReceipt = await publicClient!.waitForTransactionReceipt({ hash });
      if (regReceipt.status === "reverted") throw new Error(`Register TX reverted: ${hash}`);

      const envelopeHash = hashEnvelope(envelope);
      const capHash      = hashCapability(spendCap);

      // Persist to localStorage for keeper tab
      const stored = JSON.parse(localStorage.getItem(DMS_KEY) || "[]");
      stored.push(JSON.parse(JSON.stringify({
        envelopeHash, capabilityHash: capHash, positionHash: demo.positionHash,
        conditions, position: demo.position, intent, spendCap, capSig, intentSig,
        loanDeadline: deadline, agentAddress: address, registeredAt: Date.now(), triggered: false,
        scenario: "dms",
      }, bigintReplacer)));
      localStorage.setItem(DMS_KEY, JSON.stringify(stored));

      setArmed(true);
      setDemo(d => ({
        ...d,
        envelopeHash,
        capabilityHash: capHash,
        spendCap, intent, capSig, intentSig, conditions, deadline,
        checkInCount: 0,
      }));

      log("success", `DMS envelope armed — deadline ${new Date(Number(deadline) * 1000).toLocaleTimeString()}`);
      log("warn", "Agent must check in every 24 hours or funds transfer to DAO beneficiary");
    });
  }

  // ── Step 4a: Check-in (cancel + re-register) ───────────────────────────────
  async function checkIn() {
    await withBusy("checkin", async () => {
      if (!walletClient || !demo.envelopeHash) throw new Error("register DMS first");

      log("info", "Checking in — cancelling current envelope…");
      const cancelHash = await walletClient.writeContract({
        address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
        abi: REGISTRY_ABI,
        functionName: "cancel",
        args: [demo.envelopeHash],
      });
      await publicClient!.waitForTransactionReceipt({ hash: cancelHash });
      log("success", "Envelope cancelled — re-registering with fresh 24h deadline…");

      // Re-register with a new deadline and fresh nonces.
      // Use on-chain block.timestamp — Anvil may be time-warped from a previous run.
      const latestBlockCI = await publicClient!.getBlock({ blockTag: "latest" });
      const now           = latestBlockCI.timestamp;
      const deadline      = now + BigInt(HEARTBEAT_SEC);
      const capExpiry     = now + BigInt(30 * 24 * 60 * 60);
      const capNonce   = randomSalt();
      const intentNonce = randomSalt();
      const manageNonce = randomSalt();

      if (!demo.position) throw new Error("No position — restart from step 2");

      const adapterData = encodeAbiParameters([{ type: "address" }], [DAO_BENEFICIARY as `0x${string}`]);

      const spendCap = buildCapability({
        issuer: address!, grantee: address!, expiry: capExpiry, nonce: capNonce,
        constraints: {
          maxSpendPerPeriod: 0n, periodDuration: 0n, minReturnBps: 0n,
          allowedAdapters: [ADDRESSES.DirectTransferAdapter as `0x${string}`],
          allowedTokensIn:  [ADDRESSES.MockUSDC as `0x${string}`],
          allowedTokensOut: [ADDRESSES.MockUSDC as `0x${string}`],
        },
      });

      const intent = buildIntent({
        position: demo.position, capability: spendCap,
        adapter: ADDRESSES.DirectTransferAdapter as `0x${string}`, adapterData,
        minReturn: 1n, deadline: capExpiry, nonce: intentNonce,
        outputToken: ADDRESSES.MockUSDC as `0x${string}`, returnTo: ZERO_ADDRESS,
        submitter: ADDRESSES.EnvelopeRegistry as `0x${string}`, solverFeeBps: 0,
      });

      const manageCap = buildManageCapability({
        issuer: address!, grantee: address!, expiry: capExpiry, nonce: manageNonce,
      });

      const conditions: Conditions = {
        priceOracle: ADDRESSES.MockTimestampOracle as `0x${string}`,
        baseToken: ZERO_ADDRESS, quoteToken: ZERO_ADDRESS,
        triggerPrice: deadline, op: ComparisonOp.GREATER_THAN,
        secondaryOracle: ZERO_ADDRESS, secondaryTriggerPrice: 0n,
        secondaryOp: ComparisonOp.LESS_THAN, logicOp: LogicOp.AND,
      };

      const envelope = buildEnvelope({
        position: demo.position, conditions, intent, manageCapability: manageCap,
        expiry: deadline + BigInt(48 * 60 * 60), keeperRewardBps: 10, minKeeperRewardWei: 0n,
      });

      const capSig       = await signCapability(walletClient, spendCap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);
      const intentSig    = await signIntent(walletClient, intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);
      const manageCapSig = await signManageCapability(walletClient, manageCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

      const regHash = await walletClient.writeContract({
        address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
        abi: REGISTRY_ABI,
        functionName: "register",
        args: [envelope as never, manageCap as never, manageCapSig, demo.position as never],
      });
      await publicClient!.waitForTransactionReceipt({ hash: regHash });

      const envelopeHash = hashEnvelope(envelope);
      const capHash      = hashCapability(spendCap);

      setDemo(d => ({
        ...d,
        envelopeHash, capabilityHash: capHash,
        spendCap, intent, capSig, intentSig, conditions, deadline,
        checkInCount: (d.checkInCount ?? 0) + 1,
      }));

      log("success", `Check-in #${(demo.checkInCount ?? 0) + 1} complete — new deadline ${new Date(Number(deadline) * 1000).toLocaleTimeString()}`);
      log("info", "Agent confirmed alive — DMS rearmed with fresh 24h window");
    });
  }

  // ── Step 4b / 5: Simulate going dark + keeper triggers ─────────────────────
  async function triggerSwitch() {
    await withBusy("trigger", async () => {
      if (!walletClient || !demo.envelopeHash || !demo.conditions || !demo.position || !demo.intent || !demo.spendCap || !demo.capSig || !demo.intentSig)
        throw new Error("arm the DMS first (step 3)");

      log("warn", "Agent goes dark — no check-in. Keeper detects expired heartbeat…");

      // Warp past deadline
      const deadline   = demo.deadline ?? 0n;
      const latest     = await publicClient!.getBlock({ blockTag: "latest" });
      const minTs      = latest.timestamp + 1n;
      const targetTs   = deadline + 1n > minTs ? deadline + 1n : minTs;

      await publicClient!.request({ method: "evm_setNextBlockTimestamp" as never, params: [toHex(targetTs)] as never });
      await publicClient!.request({ method: "evm_mine" as never, params: [] as never });
      log("info", `Time warped to ${new Date(Number(targetTs) * 1000).toLocaleString()} — heartbeat expired`);

      const isActive = await publicClient!.readContract({
        address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
        abi: REGISTRY_ABI,
        functionName: "isActive",
        args: [demo.envelopeHash],
      }) as boolean;
      if (!isActive) throw new Error("Envelope not active — re-register the DMS first");

      try {
        await publicClient!.simulateContract({
          address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
          abi: REGISTRY_ABI,
          functionName: "trigger",
          args: [demo.envelopeHash, demo.conditions as never, demo.position as never, demo.intent as never, demo.spendCap as never, demo.capSig, demo.intentSig],
          account: address,
        });
      } catch (simErr: unknown) {
        const msg = simErr instanceof Error ? simErr.message : String(simErr);
        throw new Error(`Trigger sim failed: ${msg.slice(0, 400)}`);
      }

      const hash = await walletClient.writeContract({
        address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
        abi: REGISTRY_ABI,
        functionName: "trigger",
        args: [demo.envelopeHash, demo.conditions as never, demo.position as never, demo.intent as never, demo.spendCap as never, demo.capSig, demo.intentSig],
      });
      const receipt = await publicClient!.waitForTransactionReceipt({ hash });
      if (receipt.status === "reverted") throw new Error(`Trigger TX reverted: ${hash}`);

      setFired(true);
      log("success", `Dead Man's Switch fired! tx ${hash.slice(0, 10)}…`);
      log("success", `DAO beneficiary received $${(Number(TREASURY_AMT) / 1e6 - 0.000001).toFixed(2)} USDC`);
      log("info", "1 dust unit (0.000001 USDC) retained as vault position residual");
    });
  }

  function resetDemo() {
    setDemo({});
    setArmed(false);
    setFired(false);
    setBeneficiaryBalance(0n);
    setLogs([]);
    log("info", "Demo reset — ready for a new run");
  }

  const hasTreasury  = demo.positionHash !== undefined;
  const hasEnvelope  = armed && demo.envelopeHash !== undefined;
  const checkInCount = demo.checkInCount ?? 0;

  return (
    <div className="flex-1 p-6 grid grid-cols-1 lg:grid-cols-3 gap-6 max-w-7xl mx-auto w-full">

      {/* Left: step flow */}
      <div className="lg:col-span-2 flex flex-col gap-4">

        {/* Explainer */}
        <div className="rounded-2xl border border-amber-800/40 bg-amber-950/20 p-5">
          <div className="flex items-start gap-4">
            <span className="text-3xl mt-0.5">🛡️</span>
            <div>
              <h2 className="text-lg font-bold text-amber-300 mb-1">Dead Man's Switch</h2>
              <p className="text-sm text-zinc-400 leading-relaxed">
                An AI agent manages a <strong className="text-white">$2,000 USDC</strong> DAO treasury.
                It pre-signs a failsafe: if it stops checking in for{" "}
                <strong className="text-amber-300">24 hours</strong>, the full treasury is transferred
                to the <strong className="text-white">DAO multisig</strong> — permissionlessly, by any keeper.
                No agent involvement needed at execution time.
              </p>
              <div className="mt-3 grid grid-cols-3 gap-2 text-xs">
                <div className="rounded-lg bg-zinc-800/50 p-2 text-center">
                  <div className="text-amber-300 font-bold">Liveness-free</div>
                  <div className="text-zinc-500">No agent needed to trigger</div>
                </div>
                <div className="rounded-lg bg-zinc-800/50 p-2 text-center">
                  <div className="text-amber-300 font-bold">Key-compromise-safe</div>
                  <div className="text-zinc-500">Attacker can't redirect to self</div>
                </div>
                <div className="rounded-lg bg-zinc-800/50 p-2 text-center">
                  <div className="text-amber-300 font-bold">EIP-712 bound</div>
                  <div className="text-zinc-500">Beneficiary signed at setup</div>
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Connect prompt */}
        {!isConnected && (
          <div className="rounded-2xl border border-zinc-800 bg-zinc-900/50 p-6 text-center">
            <p className="text-zinc-400">Connect your wallet (Anvil :8545, chainId 31337) to run this scenario.</p>
          </div>
        )}

        {/* Step 0 — Mint treasury */}
        <StepCard
          step={0}
          title="Fund agent treasury — mint USDC"
          subtitle={`The AI agent controls $${Number(TREASURY_AMT) / 1e6} USDC on behalf of the DAO. Simulate by minting.`}
          status={!isConnected ? "pending" : hasTreasury ? "done" : "ready"}
        >
          <TxButton label={`Mint $${Number(TREASURY_AMT) / 1e6} USDC`} onClick={mintTreasury} loading={busy["mint"]} disabled={!isConnected || hasTreasury} />
        </StepCard>

        {/* Step 1 — Beneficiary info */}
        <StepCard
          step={1}
          title="DAO multisig set as failsafe beneficiary"
          subtitle="The beneficiary address is baked into the intent via EIP-712. It cannot be changed post-registration without the agent's signature."
          status={!isConnected ? "pending" : "ready"}
        >
          <div className="rounded-xl border border-zinc-700 bg-zinc-800/40 p-3 text-xs font-mono flex items-center justify-between gap-2">
            <div>
              <div className="text-zinc-500 mb-0.5">DAO Beneficiary (Anvil account 1)</div>
              <div className="text-amber-300">{DAO_BENEFICIARY}</div>
            </div>
            <div className="text-right shrink-0">
              <div className="text-zinc-500 mb-0.5">Receives</div>
              <div className="text-zinc-200">~${(Number(TREASURY_AMT) / 1e6).toFixed(2)} USDC</div>
            </div>
          </div>
        </StepCard>

        {/* Step 2 — Deposit */}
        <StepCard
          step={2}
          title="Lock treasury in Atlas vault"
          subtitle="USDC deposited as a UTXO-style position. The vault encumbers the position once the envelope is registered — agent cannot withdraw."
          status={!isConnected ? "pending" : hasTreasury ? "done" : "pending"}
        >
          <div className="flex items-center gap-3">
            <TxButton label={`Deposit $${Number(TREASURY_AMT) / 1e6} USDC`} onClick={depositTreasury} loading={busy["deposit"]} disabled={!isConnected || hasTreasury} />
            {demo.positionHash && <span className="text-xs text-emerald-400 font-mono">{demo.positionHash.slice(0, 18)}…</span>}
          </div>
        </StepCard>

        {/* Step 3 — Register DMS */}
        <StepCard
          step={3}
          title="Arm the Dead Man's Switch"
          subtitle="Signs a failsafe envelope: if timestamp > (lastCheckIn + 24h), transfer all funds to DAO. Agent can now go offline safely."
          status={!isConnected ? "pending" : hasEnvelope ? "done" : hasTreasury ? "ready" : "pending"}
        >
          <div className="flex flex-col gap-3">
            <div className="text-xs text-zinc-500 space-y-0.5">
              <div>Condition: <span className="text-zinc-300">block.timestamp &gt; lastHeartbeat + 24h</span></div>
              <div>Adapter: <span className="text-zinc-300">DirectTransferAdapter → DAO multisig</span></div>
              <div>Beneficiary: <span className="text-amber-400 font-mono">{DAO_BENEFICIARY.slice(0, 14)}…</span></div>
            </div>
            <TxButton label="Arm DMS Envelope" onClick={registerDms} loading={busy["register"]} disabled={!isConnected || !hasTreasury || hasEnvelope} variant="keeper" />
            {hasEnvelope && (
              <div className="rounded-xl border border-amber-800/40 bg-amber-950/20 px-4 py-2.5 flex items-center gap-3">
                <span className="text-xl">🛡️</span>
                <div>
                  <p className="text-xs font-medium text-amber-300">Dead Man's Switch ARMED</p>
                  <p className="text-xs text-zinc-600">Envelope: {demo.envelopeHash?.slice(0, 18)}…</p>
                </div>
              </div>
            )}
          </div>
        </StepCard>

        {/* Step 4 — Check-in or Go Dark */}
        <StepCard
          step={4}
          title="Heartbeat check-in or go dark"
          subtitle="While the agent is alive, it cancels and re-registers with a fresh 24h deadline. If it stops, the switch fires."
          status={!isConnected ? "pending" : fired ? "done" : hasEnvelope ? "ready" : "pending"}
        >
          <div className="flex flex-col gap-3">
            <div className="grid grid-cols-2 gap-3">
              {/* Check-in option */}
              <div className="rounded-xl border border-emerald-800/30 bg-emerald-950/20 p-3 flex flex-col gap-2">
                <div className="flex items-center gap-2">
                  <span className="text-lg">💚</span>
                  <span className="text-xs font-medium text-emerald-300">Agent alive — check in</span>
                </div>
                <p className="text-xs text-zinc-500">Cancel envelope + re-register with a fresh 24h deadline. Resets the countdown.</p>
                {checkInCount > 0 && (
                  <div className="text-xs text-emerald-400">✓ {checkInCount} check-in{checkInCount !== 1 ? "s" : ""} completed</div>
                )}
                <TxButton label={`Check In ${checkInCount > 0 ? `(#${checkInCount + 1})` : ""}`} onClick={checkIn} loading={busy["checkin"]} disabled={!hasEnvelope || fired} variant="secondary" />
              </div>

              {/* Go dark option */}
              <div className="rounded-xl border border-red-800/30 bg-red-950/20 p-3 flex flex-col gap-2">
                <div className="flex items-center gap-2">
                  <span className="text-lg">💀</span>
                  <span className="text-xs font-medium text-red-400">Agent goes dark</span>
                </div>
                <p className="text-xs text-zinc-500">Skip check-in. Warp time past deadline. Keeper fires the switch.</p>
                <TxButton label="Trigger Switch (Keeper)" onClick={triggerSwitch} loading={busy["trigger"]} disabled={!hasEnvelope || fired} variant="keeper" />
              </div>
            </div>
          </div>
        </StepCard>

        {/* Result */}
        {fired && (
          <div className="rounded-2xl border border-amber-700 bg-amber-950/30 p-5 flex items-start gap-4">
            <span className="text-3xl mt-0.5">✅</span>
            <div>
              <p className="text-amber-300 font-semibold text-sm mb-1">
                Dead Man's Switch executed successfully
              </p>
              <p className="text-zinc-400 text-xs leading-relaxed">
                ${(Number(TREASURY_AMT) / 1e6 - 0.000001).toFixed(2)} USDC transferred to DAO multisig.
                {beneficiaryBalance > 0n && (
                  <span className="text-emerald-400 ml-1">
                    DAO balance: ${(Number(beneficiaryBalance) / 1e6).toFixed(2)} USDC confirmed on-chain.
                  </span>
                )}
              </p>
              <div className="mt-3 flex gap-2">
                <button
                  onClick={resetDemo}
                  className="text-xs px-3 py-1.5 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-300 border border-zinc-700 transition-colors"
                >
                  Run again →
                </button>
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Right panel */}
      <div className="flex flex-col gap-4">

        {/* DMS status card */}
        <div className="rounded-2xl border border-zinc-700 bg-zinc-900 p-5">
          <h3 className="text-sm font-semibold text-zinc-200 mb-4 flex items-center gap-2">
            <span>🛡️</span> Switch Status
          </h3>

          <div className="space-y-3 text-xs">
            <StatusRow
              label="State"
              value={fired ? "FIRED" : hasEnvelope ? "ARMED" : hasTreasury ? "READY" : "IDLE"}
              color={fired ? "text-amber-400" : hasEnvelope ? "text-emerald-400" : hasTreasury ? "text-indigo-400" : "text-zinc-500"}
            />
            <StatusRow label="Treasury" value={hasTreasury ? `$${Number(TREASURY_AMT) / 1e6}` : "—"} />
            <StatusRow label="Beneficiary" value={DAO_BENEFICIARY.slice(0, 12) + "…"} mono />
            <StatusRow label="Heartbeat" value={demo.deadline ? new Date(Number(demo.deadline) * 1000).toLocaleTimeString() : "—"} />
            <StatusRow label="Check-ins" value={checkInCount.toString()} />
            <StatusRow label="DAO received" value={beneficiaryBalance > 0n ? `$${(Number(beneficiaryBalance) / 1e6).toFixed(2)}` : "—"} color={beneficiaryBalance > 0n ? "text-emerald-400" : "text-zinc-500"} />
          </div>

          {/* Countdown visual */}
          {hasEnvelope && !fired && demo.deadline && (
            <div className="mt-4 rounded-xl border border-amber-800/30 bg-amber-950/20 p-3">
              <div className="flex items-center justify-between text-xs mb-2">
                <span className="text-zinc-500">Next check-in deadline</span>
                <span className="text-amber-400 font-medium">
                  {new Date(Number(demo.deadline) * 1000).toLocaleTimeString()}
                </span>
              </div>
              <div className="text-xs text-zinc-600">
                {checkInCount > 0 ? `${checkInCount} heartbeat${checkInCount !== 1 ? "s" : ""} sent — agent confirmed alive` : "No check-ins yet — clock is running"}
              </div>
            </div>
          )}
        </div>

        {/* How it works */}
        <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
          <h3 className="text-sm font-semibold text-zinc-200 mb-3">How Atlas Enforces This</h3>
          <ol className="space-y-2 text-xs text-zinc-500">
            {[
              "Agent pre-signs failsafe intent at vault setup (EIP-712)",
              "Intent encodes beneficiary address — cannot be forged",
              "Envelope condition: block.timestamp > heartbeat + 24h",
              "Any keeper calls trigger() once condition is met",
              "DirectTransferAdapter forwards treasury to beneficiary",
              "No agent key, signature, or online presence needed",
            ].map((step, i) => (
              <li key={i} className="flex items-start gap-2">
                <span className="text-amber-700 font-mono shrink-0">{i + 1}.</span>
                <span>{step}</span>
              </li>
            ))}
          </ol>
        </div>

        {/* Use cases */}
        <details className="rounded-2xl border border-zinc-800 bg-zinc-900">
          <summary className="px-4 py-3 text-xs font-semibold text-zinc-400 cursor-pointer select-none">
            Real-world applications
          </summary>
          <div className="px-4 pb-4 pt-1 space-y-2 text-xs text-zinc-500">
            {[
              ["DAO treasury protection", "Unused AI budget returned to DAO if agent offline"],
              ["Agent escrow", "Payment released to counterparty on task completion or timeout"],
              ["Inheritance vaults", "Crypto inheritance auto-triggers after inactivity period"],
              ["Circuit breaker", "Protocol funds moved to cold storage if agent misbehaves"],
            ].map(([title, desc]) => (
              <div key={title} className="rounded-lg bg-zinc-800/40 p-2">
                <div className="text-zinc-300 font-medium mb-0.5">{title}</div>
                <div>{desc}</div>
              </div>
            ))}
          </div>
        </details>

        {/* Log */}
        <div>
          <h2 className="text-sm font-semibold text-zinc-300 mb-2">Activity Log</h2>
          <LogPanel entries={logs} />
        </div>
      </div>
    </div>
  );
}

function StatusRow({ label, value, mono, color }: { label: string; value: string; mono?: boolean; color?: string }) {
  return (
    <div className="flex justify-between gap-2 items-baseline">
      <span className="text-zinc-500">{label}</span>
      <span className={`${mono ? "font-mono" : ""} ${color ?? "text-zinc-200"}`}>{value}</span>
    </div>
  );
}
