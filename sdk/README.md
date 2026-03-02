# @atlas-protocol/sdk

TypeScript SDK for building, hashing, and signing Atlas Protocol primitives.

Mirrors every on-chain hash in `HashLib.sol` exactly — a mismatch causes on-chain revert.

## Install

From the repo root the UI references this package via `file:../sdk`. To use standalone:

```bash
cd sdk
npm install
```

## Build

```bash
npm run build
```

Output goes to `dist/`. The UI imports from `dist/` via the `exports` field in `package.json`.

## Test

```bash
npm test
```

- `eip712-parity.test.ts` — cross-checks every SDK hash against the Solidity output deployed on a local Anvil node. Requires `forge build` and Anvil to be running.
- `integration.test.ts` — runs the full register → trigger lifecycle via the SDK against live contracts.
- `debug.test.ts` — one-off helpers for diagnosing hash mismatches during development.

Integration tests require Foundry artifacts (`../out`) and Anvil running at `http://127.0.0.1:8545`.

---

## API reference

### Types

```ts
import type { Position, Constraints, Capability, Intent, Conditions, Envelope } from "@atlas-protocol/sdk";
import { ComparisonOp, LogicOp, SCOPE, ZERO_HASH, ZERO_ADDRESS } from "@atlas-protocol/sdk";
```

### EIP-712 hashing

```ts
import {
  kernelDomain,        // EIP-712 domain for CapabilityKernel
  registryDomain,      // EIP-712 domain for EnvelopeRegistry
  hashCapability,      // keccak256 of a Capability struct (for kernel domain)
  hashEnvelope,        // keccak256 of an Envelope struct (for registry domain)
  hashConstraints,     // keccak256 of a Constraints struct
} from "@atlas-protocol/sdk";
```

### Position utilities

```ts
import { hashPosition, buildPosition, randomSalt, hashNullifier } from "@atlas-protocol/sdk";

const salt = randomSalt();                     // random bytes32
const pos = buildPosition(owner, asset, amt, salt);
const hash = hashPosition(pos);               // keccak256(abi.encode(Position))
```

### Builders

```ts
import {
  noConstraints,
  buildCapability,          // vault.spend Capability
  buildManageCapability,    // envelope.manage Capability
  buildIntent,
  buildEnvelope,
  hashConditions,           // keccak256(abi.encode(Conditions))
  hashIntentCommitment,     // keccak256(abi.encode(intent)) — tuple encoding, matches Solidity
} from "@atlas-protocol/sdk";
```

> **Important**: `hashIntentCommitment` encodes Intent as a single `tuple` argument to match
> Solidity's `abi.encode(intent)` which emits a 32-byte outer offset header for dynamic structs.
> Using flat argument encoding produces a different 512-byte vs 544-byte encoding and causes
> `IntentMismatch` revert on-chain.

### Signing

```ts
import { signCapability, signManageCapability, signIntent } from "@atlas-protocol/sdk";

// All three produce EIP-712 typed-data signatures.
// signCapability and signManageCapability use the CapabilityKernel domain.
// signIntent uses the CapabilityKernel domain with the Intent primary type.
const capSig    = await signCapability(walletClient, capability, kernelAddress, chainId);
const manageSig = await signManageCapability(walletClient, manageCap, registryAddress, chainId);
const intentSig = await signIntent(walletClient, intent, kernelAddress, chainId);
```

### Adapter data encoding

```ts
import { clawloanRepayLive, clawloanRepayStatic, uniswapSingleHop, aaveSupply } from "@atlas-protocol/sdk";

// Live-debt mode: adapter queries pool.getDebt() at trigger time
const adapterData = clawloanRepayLive(poolAddress, botId, debtCapBigInt);

// Static mode: debt amount baked in at envelope creation time
const adapterData = clawloanRepayStatic(poolAddress, botId, debtAmountBigInt);
```

---

## Complete Clawloan cycle example

```ts
import {
  buildCapability, buildManageCapability, buildIntent, buildEnvelope,
  signCapability, signManageCapability, signIntent,
  hashCapability, hashEnvelope, hashPosition, hashConditions, hashIntentCommitment,
  clawloanRepayLive, randomSalt, buildPosition,
  ComparisonOp, LogicOp, SCOPE, ZERO_ADDRESS, ZERO_HASH,
  noConstraints,
} from "@atlas-protocol/sdk";

const salt = randomSalt();
const position = buildPosition(operatorAddress, usdcAddress, parseUnits("15", 6), salt);
const positionHash = hashPosition(position);

// 1. vault.spend Capability
const spendCap = buildCapability({ issuer: operator, grantee: operator, expiry, nonce: randomSalt() });
const capSig = await signCapability(walletClient, chainId, kernelAddress, spendCap);
const capHash = hashCapability(spendCap);

// 2. Intent
const adapterData = clawloanRepayLive(poolAddress, 1n, liveDebt);
const intent = buildIntent({
  positionHash, capabilityHash: capHash, adapter: clawloanAdapterAddress,
  adapterData, minReturn: parseUnits("2", 6), deadline,
  nonce: randomSalt(), outputToken: usdcAddress,
  returnTo: vaultAddress, submitter: operatorAddress,
});
const intentSig = await signIntent(walletClient, chainId, kernelAddress, intent);

// 3. envelope.manage Capability + Envelope
const manageCap = buildManageCapability({ issuer: operator, grantee: operator, expiry, nonce: randomSalt() });
const manageSig = await signManageCapability(walletClient, chainId, kernelAddress, manageCap);
const conditions: Conditions = {
  priceOracle: timestampOracleAddress, baseToken: ZERO_ADDRESS, quoteToken: ZERO_ADDRESS,
  triggerPrice: deadline, op: ComparisonOp.GREATER_THAN,
  secondaryOracle: ZERO_ADDRESS, secondaryTriggerPrice: 0n,
  secondaryOp: ComparisonOp.LESS_THAN, logicOp: LogicOp.AND,
};
const envelope = buildEnvelope({
  positionCommitment: positionHash, conditions, intent,
  capabilityHash: capHash, expiry: deadline + 86400n,
  keeperRewardBps: 50, minKeeperRewardWei: 0n,
});
const envelopeHash = hashEnvelope(envelope);

// 4. Register on-chain
await walletClient.writeContract({
  address: registryAddress, abi: REGISTRY_ABI,
  functionName: "register",
  args: [envelope, manageCap, manageSig],
});

// 5. Trigger (by any keeper once condition is met)
await walletClient.writeContract({
  address: registryAddress, abi: REGISTRY_ABI,
  functionName: "trigger",
  args: [envelopeHash, conditions, intent, spendCap, capSig, intentSig],
});
```
