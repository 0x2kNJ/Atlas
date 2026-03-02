/**
 * Atlas Protocol SDK — Integration Tests
 *
 * Starts a private Anvil node, deploys all Atlas contracts, and runs every
 * test against the live node.  Everything lives in a single `beforeAll` /
 * `afterAll` pair so there are no cross-process communication issues.
 *
 * Verifies:
 * 1. SDK EIP-712 digests match what the deployed kernel returns.
 * 2. The full executeIntent round-trip succeeds end-to-end.
 * 3. A tampered signature is rejected.
 * 4. An expired capability is rejected.
 * 5. An unapproved solver is rejected.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  encodeAbiParameters,
  hashTypedData,
  recoverTypedDataAddress,
  parseEventLogs,
  type Address,
  type Hex,
  type WalletClient,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";
import { createAnvil, type Anvil } from "@viem/anvil";
import {
  hashCapability,
  kernelDomain,
  ATLAS_TYPES,
} from "../src/eip712.js";
import { signCapability, signIntent } from "../src/signing.js";
import { SCOPE, ZERO_HASH, ZERO_ADDRESS } from "../src/types.js";
import type { Capability, Constraints, Intent } from "../src/types.js";
import { ARTIFACTS } from "./helpers/artifacts.js";

// ─────────────────────────────────────────────────────────────────────────────
// Deterministic Anvil dev accounts
// ─────────────────────────────────────────────────────────────────────────────

const ownerAccount  = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const aliceAccount  = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const bobAccount    = privateKeyToAccount("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a");
const solverAccount = privateKeyToAccount("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6");

const CHAIN_ID = 31337;
const AMOUNT   = 1_000_000_000n;           // 1 000 USDC  (6 decimals)
const OUTPUT   = 500_000_000_000_000_000n; // 0.5 WETH   (18 decimals)

// ─────────────────────────────────────────────────────────────────────────────
// Shared test context — populated by beforeAll
// ─────────────────────────────────────────────────────────────────────────────

let anvil: Anvil;
let ownsAnvilProcess = false;
let publicClient: PublicClient;
let aliceWallet:  WalletClient;
let bobWallet:    WalletClient;
let solverWallet: WalletClient;
let ownerWallet:  WalletClient;

let kernelAddr:  Address;
let vaultAddr:   Address;
let adapterAddr: Address;
let usdcAddr:    Address;
let wethAddr:    Address;

// ─────────────────────────────────────────────────────────────────────────────
// Setup / teardown
// ─────────────────────────────────────────────────────────────────────────────

beforeAll(async () => {
  anvil = createAnvil({ chainId: CHAIN_ID });
  let rpcUrl = "http://127.0.0.1:8545";
  try {
    await anvil.start();
    ownsAnvilProcess = true;
    rpcUrl = `http://127.0.0.1:${anvil.port}`;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!message.includes("Address already in use")) throw error;
  }

  const transport = http(rpcUrl);
  publicClient = createPublicClient({ chain: foundry, transport }) as PublicClient;
  ownerWallet  = createWalletClient({ chain: foundry, transport, account: ownerAccount });
  aliceWallet  = createWalletClient({ chain: foundry, transport, account: aliceAccount });
  bobWallet    = createWalletClient({ chain: foundry, transport, account: bobAccount });
  solverWallet = createWalletClient({ chain: foundry, transport, account: solverAccount });

  // ── helpers ────────────────────────────────────────────────────────────────
  async function deploy(
    artifact: { abi: unknown[]; bytecode: `0x${string}` },
    args: unknown[] = [],
  ): Promise<Address> {
    const hash = await ownerWallet.deployContract({
      abi:      artifact.abi as never,
      bytecode: artifact.bytecode,
      args:     args as never,
      account:  ownerAccount,
      chain:    foundry,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (!receipt.contractAddress) throw new Error("deploy failed — no contractAddress");
    return receipt.contractAddress;
  }

  async function write(address: Address, abi: unknown[], fn: string, args: unknown[] = []) {
    const hash = await ownerWallet.writeContract({
      address,
      abi:          abi as never,
      functionName: fn,
      args:         args as never,
      account:      ownerAccount,
      chain:        foundry,
    });
    await publicClient.waitForTransactionReceipt({ hash });
  }

  // ── deploy contracts ───────────────────────────────────────────────────────
  const vaultArt   = ARTIFACTS.SingletonVault();
  const kernelArt  = ARTIFACTS.CapabilityKernel();
  const adapterArt = ARTIFACTS.MockAdapter();
  const erc20Art   = ARTIFACTS.MockERC20();

  vaultAddr   = await deploy(vaultArt,   [ownerAccount.address, false]);
  kernelAddr  = await deploy(kernelArt,  [vaultAddr, ownerAccount.address]);
  adapterAddr = await deploy(adapterArt, []);
  usdcAddr    = await deploy(erc20Art,   ["USD Coin",      "USDC", 6]);
  wethAddr    = await deploy(erc20Art,   ["Wrapped Ether", "WETH", 18]);

  // ── wire contracts ─────────────────────────────────────────────────────────
  await write(vaultAddr,   vaultArt.abi,   "setKernel",        [kernelAddr]);
  await write(kernelAddr,  kernelArt.abi,  "registerAdapter",  [adapterAddr]);
  await write(kernelAddr,  kernelArt.abi,  "setSolver",        [solverAccount.address, true]);

  // ── seed balances ──────────────────────────────────────────────────────────
  await write(usdcAddr,    erc20Art.abi,   "mint",             [aliceAccount.address, AMOUNT * 20n]);
  await write(wethAddr,    erc20Art.abi,   "mint",             [adapterAddr, OUTPUT * 100n]);
  await write(adapterAddr, adapterArt.abi, "setMockAmountOut", [OUTPUT]);
}, 120_000);

afterAll(async () => {
  if (ownsAnvilProcess) {
    await anvil.stop();
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// Fixture factories
// ─────────────────────────────────────────────────────────────────────────────

function makeConstraints(): Constraints {
  return {
    maxSpendPerPeriod: AMOUNT * 5n,
    periodDuration:    86400n,
    minReturnBps:      9500n,
    allowedAdapters:   [adapterAddr],
    allowedTokensIn:   [usdcAddr],
    allowedTokensOut:  [wethAddr],
  };
}

function makeCapability(overrides: Partial<Capability> = {}): Capability {
  return {
    issuer:               aliceAccount.address,
    grantee:              bobAccount.address,
    scope:                SCOPE.VAULT_SPEND,
    expiry:               2_000_000_000n,
    nonce:                keccak256(encodeAbiParameters(
      [{ type: "uint256" }],
      [BigInt(Date.now()) + BigInt(Math.floor(Math.random() * 1_000_000))],
    )) as Hex,
    constraints:          makeConstraints(),
    parentCapabilityHash: ZERO_HASH,
    delegationDepth:      0,
    ...overrides,
  };
}

function makeIntent(cap: Capability, posCommitment: Hex, overrides: Partial<Intent> = {}): Intent {
  return {
    positionCommitment: posCommitment,
    capabilityHash:     hashCapability(cap),
    adapter:            adapterAddr,
    adapterData:        "0x" as Hex,
    minReturn:          OUTPUT,
    deadline:           2_000_000_000n,
    nonce:              keccak256(encodeAbiParameters(
      [{ type: "uint256" }],
      [BigInt(Date.now()) + BigInt(Math.floor(Math.random() * 1_000_000))],
    )) as Hex,
    outputToken:        wethAddr,
    returnTo:           vaultAddr,
    submitter:          ZERO_ADDRESS,
    solverFeeBps:       0,
    ...overrides,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Deposit helper — mints + approves + deposits a fresh USDC position for Alice.
// Returns both the on-chain positionHash and the full position tuple needed
// to call executeIntent (the contract reconstructs the hash from the tuple).
// ─────────────────────────────────────────────────────────────────────────────

interface DepositResult {
  positionHash: Hex;
  position: { owner: `0x${string}`; asset: `0x${string}`; amount: bigint; salt: Hex };
}

async function depositPosition(salt: Hex): Promise<DepositResult> {
  const vaultArt = ARTIFACTS.SingletonVault();
  const erc20Art = ARTIFACTS.MockERC20();

  const mintHash = await ownerWallet.writeContract({
    address: usdcAddr, abi: erc20Art.abi as never,
    functionName: "mint", args: [aliceAccount.address, AMOUNT] as never,
    account: ownerAccount, chain: foundry,
  });
  await publicClient.waitForTransactionReceipt({ hash: mintHash });

  const approveHash = await aliceWallet.writeContract({
    address: usdcAddr, abi: erc20Art.abi as never,
    functionName: "approve", args: [vaultAddr, AMOUNT] as never,
    account: aliceAccount, chain: foundry,
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  const depositHash = await aliceWallet.writeContract({
    address: vaultAddr, abi: vaultArt.abi as never,
    functionName: "deposit", args: [usdcAddr, AMOUNT, salt] as never,
    account: aliceAccount, chain: foundry,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash: depositHash });

  const logs = parseEventLogs({
    abi:       vaultArt.abi as never,
    eventName: "PositionCreated",
    logs:      receipt.logs,
  });
  if (logs.length === 0) throw new Error("PositionCreated event not found in receipt");

  const positionHash = (logs[0] as { args: { positionHash: Hex } }).args.positionHash;
  return {
    positionHash,
    position: { owner: aliceAccount.address, asset: usdcAddr, amount: AMOUNT, salt },
  };
}

// ── Helpers to convert SDK types into plain ABI-compatible objects ────────────

function capArgs(cap: Capability) {
  return {
    issuer:               cap.issuer,
    grantee:              cap.grantee,
    scope:                cap.scope,
    expiry:               cap.expiry,
    nonce:                cap.nonce,
    constraints: {
      maxSpendPerPeriod: cap.constraints.maxSpendPerPeriod,
      periodDuration:    cap.constraints.periodDuration,
      minReturnBps:      cap.constraints.minReturnBps,
      allowedAdapters:   cap.constraints.allowedAdapters,
      allowedTokensIn:   cap.constraints.allowedTokensIn,
      allowedTokensOut:  cap.constraints.allowedTokensOut,
    },
    parentCapabilityHash: cap.parentCapabilityHash,
    delegationDepth:      cap.delegationDepth,
  };
}

function intentArgs(intent: Intent) {
  return {
    positionCommitment: intent.positionCommitment,
    capabilityHash:     intent.capabilityHash,
    adapter:            intent.adapter,
    adapterData:        intent.adapterData,
    minReturn:          intent.minReturn,
    deadline:           intent.deadline,
    nonce:              intent.nonce,
    outputToken:        intent.outputToken,
    returnTo:           intent.returnTo,
    submitter:          intent.submitter,
    solverFeeBps:       intent.solverFeeBps,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 1: EIP-712 digest parity — SDK vs on-chain kernel
// ─────────────────────────────────────────────────────────────────────────────

describe("EIP-712 digest parity (SDK vs deployed kernel)", () => {
  it("capabilityDigest: SDK hashTypedData matches kernel.capabilityDigest()", async () => {
    const kernelArt = ARTIFACTS.CapabilityKernel();
    const cap = makeCapability();

    const sdkDigest = hashTypedData({
      domain:      kernelDomain(kernelAddr, CHAIN_ID),
      types:       ATLAS_TYPES,
      primaryType: "Capability",
      message:     capArgs(cap),
    });

    const onChainDigest = await publicClient.readContract({
      address:      kernelAddr,
      abi:          kernelArt.abi,
      functionName: "capabilityDigest",
      args:         [capArgs(cap)],
    }) as Hex;

    expect(sdkDigest).toBe(onChainDigest);
  });

  it("intentDigest: SDK hashTypedData matches kernel.intentDigest()", async () => {
    const kernelArt = ARTIFACTS.CapabilityKernel();
    const cap    = makeCapability();
    const intent = makeIntent(cap, "0x1111111111111111111111111111111111111111111111111111111111111111" as Hex);

    const sdkDigest = hashTypedData({
      domain:      kernelDomain(kernelAddr, CHAIN_ID),
      types:       ATLAS_TYPES,
      primaryType: "Intent",
      message:     intentArgs(intent),
    });

    const onChainDigest = await publicClient.readContract({
      address:      kernelAddr,
      abi:          kernelArt.abi,
      functionName: "intentDigest",
      args:         [intentArgs(intent)],
    }) as Hex;

    expect(sdkDigest).toBe(onChainDigest);
  });

  it("signCapability produces a signature that ecrecovers to alice", async () => {
    const cap = makeCapability();
    const sig = await signCapability(aliceWallet, cap, kernelAddr, CHAIN_ID);

    const recovered = await recoverTypedDataAddress({
      domain:      kernelDomain(kernelAddr, CHAIN_ID),
      types:       ATLAS_TYPES,
      primaryType: "Capability",
      message:     capArgs(cap),
      signature:   sig,
    });

    expect(recovered.toLowerCase()).toBe(aliceAccount.address.toLowerCase());
  });

  it("signIntent produces a signature that ecrecovers to bob", async () => {
    const cap    = makeCapability();
    const intent = makeIntent(cap, "0x1111111111111111111111111111111111111111111111111111111111111111" as Hex);
    const sig    = await signIntent(bobWallet, intent, kernelAddr, CHAIN_ID);

    const recovered = await recoverTypedDataAddress({
      domain:      kernelDomain(kernelAddr, CHAIN_ID),
      types:       ATLAS_TYPES,
      primaryType: "Intent",
      message:     intentArgs(intent),
      signature:   sig,
    });

    expect(recovered.toLowerCase()).toBe(bobAccount.address.toLowerCase());
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Test 2: Full executeIntent round-trip
// ─────────────────────────────────────────────────────────────────────────────

describe("executeIntent round-trip", () => {
  it("executes successfully: position consumed, nullifier marked spent", async () => {
    const kernelArt = ARTIFACTS.CapabilityKernel();
    const vaultArt  = ARTIFACTS.SingletonVault();

    const salt = keccak256(encodeAbiParameters([{ type: "uint256" }], [BigInt(Date.now()) + 100n])) as Hex;
    const { positionHash, position } = await depositPosition(salt);

    const posExists = await publicClient.readContract({
      address: vaultAddr, abi: vaultArt.abi, functionName: "positions", args: [positionHash],
    });
    expect(posExists).toBe(true);

    const cap    = makeCapability();
    const intent = makeIntent(cap, positionHash);
    const capSig    = await signCapability(aliceWallet, cap, kernelAddr, CHAIN_ID);
    const intentSig = await signIntent(bobWallet, intent, kernelAddr, CHAIN_ID);

    const execHash = await solverWallet.writeContract({
      address: kernelAddr, abi: kernelArt.abi as never,
      functionName: "executeIntent",
      args: [position, capArgs(cap), intentArgs(intent), capSig, intentSig] as never,
      account: solverAccount, chain: foundry,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash: execHash });
    expect(receipt.status).toBe("success");

    // Position is consumed.
    const posAfter = await publicClient.readContract({
      address: vaultAddr, abi: vaultArt.abi, functionName: "positions", args: [positionHash],
    });
    expect(posAfter).toBe(false);

    // Nullifier is spent.
    const nullifier = keccak256(encodeAbiParameters(
      [{ type: "bytes32" }, { type: "bytes32" }],
      [intent.nonce, positionHash],
    ));
    const isSpent = await publicClient.readContract({
      address: kernelAddr, abi: kernelArt.abi, functionName: "isSpent", args: [nullifier],
    });
    expect(isSpent).toBe(true);
  });

  it("reverts on double-spend: same nullifier cannot execute twice", async () => {
    const kernelArt = ARTIFACTS.CapabilityKernel();

    const salt = keccak256(encodeAbiParameters([{ type: "uint256" }], [BigInt(Date.now()) + 200n])) as Hex;
    const { positionHash, position } = await depositPosition(salt);
    const cap    = makeCapability();
    const intent = makeIntent(cap, positionHash);
    const capSig    = await signCapability(aliceWallet, cap, kernelAddr, CHAIN_ID);
    const intentSig = await signIntent(bobWallet, intent, kernelAddr, CHAIN_ID);

    const firstHash = await solverWallet.writeContract({
      address: kernelAddr, abi: kernelArt.abi as never,
      functionName: "executeIntent",
      args: [position, capArgs(cap), intentArgs(intent), capSig, intentSig] as never,
      account: solverAccount, chain: foundry,
    });
    await publicClient.waitForTransactionReceipt({ hash: firstHash });

    await expect(
      solverWallet.writeContract({
        address: kernelAddr, abi: kernelArt.abi as never,
        functionName: "executeIntent",
        args: [position, capArgs(cap), intentArgs(intent), capSig, intentSig] as never,
        account: solverAccount, chain: foundry,
      }),
    ).rejects.toThrow();
  });

  it("reverts when capability is expired", async () => {
    const kernelArt = ARTIFACTS.CapabilityKernel();

    const salt = keccak256(encodeAbiParameters([{ type: "uint256" }], [BigInt(Date.now()) + 300n])) as Hex;
    const { positionHash, position } = await depositPosition(salt);
    const expiredCap = makeCapability({ expiry: 1_000_000n }); // expired in 2001
    const intent     = makeIntent(expiredCap, positionHash);
    const capSig    = await signCapability(aliceWallet, expiredCap, kernelAddr, CHAIN_ID);
    const intentSig = await signIntent(bobWallet, intent, kernelAddr, CHAIN_ID);

    await expect(
      solverWallet.writeContract({
        address: kernelAddr, abi: kernelArt.abi as never,
        functionName: "executeIntent",
        args: [position, capArgs(expiredCap), intentArgs(intent), capSig, intentSig] as never,
        account: solverAccount, chain: foundry,
      }),
    ).rejects.toThrow();
  });

  it("reverts when intent signed by wrong key (not the grantee)", async () => {
    const kernelArt = ARTIFACTS.CapabilityKernel();

    const salt = keccak256(encodeAbiParameters([{ type: "uint256" }], [BigInt(Date.now()) + 400n])) as Hex;
    const { positionHash, position } = await depositPosition(salt);
    const cap    = makeCapability();
    const intent = makeIntent(cap, positionHash);
    const capSig = await signCapability(aliceWallet, cap, kernelAddr, CHAIN_ID);
    // Alice signs the intent — wrong signer for the grantee (should be Bob).
    const badSig = await signIntent(aliceWallet, intent, kernelAddr, CHAIN_ID);

    await expect(
      solverWallet.writeContract({
        address: kernelAddr, abi: kernelArt.abi as never,
        functionName: "executeIntent",
        args: [position, capArgs(cap), intentArgs(intent), capSig, badSig] as never,
        account: solverAccount, chain: foundry,
      }),
    ).rejects.toThrow();
  });

  it("reverts when unapproved solver calls executeIntent", async () => {
    const kernelArt = ARTIFACTS.CapabilityKernel();

    const salt = keccak256(encodeAbiParameters([{ type: "uint256" }], [BigInt(Date.now()) + 500n])) as Hex;
    const { positionHash, position } = await depositPosition(salt);
    const cap    = makeCapability();
    const intent = makeIntent(cap, positionHash);
    const capSig    = await signCapability(aliceWallet, cap, kernelAddr, CHAIN_ID);
    const intentSig = await signIntent(bobWallet, intent, kernelAddr, CHAIN_ID);

    // Bob is not an approved solver.
    await expect(
      bobWallet.writeContract({
        address: kernelAddr, abi: kernelArt.abi as never,
        functionName: "executeIntent",
        args: [position, capArgs(cap), intentArgs(intent), capSig, intentSig] as never,
        account: bobAccount, chain: foundry,
      }),
    ).rejects.toThrow();
  });
});
