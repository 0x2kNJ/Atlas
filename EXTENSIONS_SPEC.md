# Atlas Protocol — Extensions Technical Specification
**Version:** 0.1  
**Status:** Draft  
**Date:** February 2026

---

## Overview

This document provides the technical specification for five protocol extensions described in `EXTENSIONS.md`. Each extension is designed to be backward-compatible with the core protocol (SPEC.md) and additive to the existing data structures.

Dependencies:
- All extensions require the core protocol (SPEC.md) to be deployed
- Extensions 2–5 require the `EnvelopeRegistry` with condition tree support (SPEC.md §3.8)
- Extension 4 (Strategy NFTs) requires Extensions 1 and 3 to be live first

---

## Extension 1: Manipulation-Resistant Execution

### 1.1 TWAP Leaf Condition

A leaf condition that evaluates a time-weighted average price rather than a spot price.

```solidity
struct TWAPLeaf {
    address twapOracle;      // Uniswap V3 OracleLibrary, Chainlink TWAP, or custom
    address baseToken;
    address quoteToken;
    uint32  windowSecs;      // lookback window in seconds (min: 60, max: 86400)
    uint256 threshold;       // price * oracleDecimals
    ComparisonOp op;
}
```

**Supported TWAP oracle interfaces:**

```solidity
// Uniswap V3 OracleLibrary (TWAP via tick accumulator)
interface IUniswapV3TWAPOracle {
    function consult(
        address pool,
        uint32  secondsAgo
    ) external view returns (int24 arithmeticMeanTick, uint128 harmonicMeanLiquidity);
}

// Chainlink aggregator with TWAP (custom, uses historical round data)
interface IChainlinkTWAP {
    function getTWAP(
        address feed,
        uint32  windowSecs
    ) external view returns (uint256 twapPrice, uint256 observationsUsed);
}

// Protocol-level TWAP registry (curated, governance-approved feeds)
interface IAtlasTWAPRegistry {
    function getRegisteredTWAPOracle(
        address baseToken,
        address quoteToken,
        uint32  windowSecs
    ) external view returns (address twapOracle, bool isApproved);
}
```

**Evaluation in EnvelopeRegistry:**

```solidity
function evaluateTWAPLeaf(TWAPLeaf memory leaf) internal view returns (bool satisfied) {
    (address twapOracle, bool isApproved) = atlasTWAPRegistry.getRegisteredTWAPOracle(
        leaf.baseToken,
        leaf.quoteToken,
        leaf.windowSecs
    );
    require(isApproved, "TWAP_ORACLE_NOT_APPROVED");
    
    uint256 twapPrice = ITWAPOracle(twapOracle).getPrice(leaf.windowSecs);
    return evaluateComparison(twapPrice, leaf.op, leaf.threshold);
}
```

**SDK integration:**

```typescript
// Build a TWAP leaf condition
const twapLeaf = sdk.conditionTree.twap({
  baseToken: 'ETH',
  quoteToken: 'USD',
  window: '15m',          // '1m' | '5m' | '15m' | '1h' | '4h' | '24h'
  threshold: parseUnits('1800', 8),
  op: 'LESS_THAN'
});

// Validate window is available for this token pair
const available = await sdk.conditionTree.availableTWAPWindows('ETH', 'USD');
// ['5m', '15m', '1h', '4h', '24h']
```

**Minimum TWAP window enforcement (SDK-level defaults):**

```typescript
const SDK_TWAP_MINIMUMS = {
  positionSizeUSD_lt_10k:    0,        // spot allowed
  positionSizeUSD_lt_100k:   '5m',     // minimum 5-minute TWAP
  positionSizeUSD_lt_1M:     '15m',    // minimum 15-minute TWAP
  positionSizeUSD_gte_1M:    '1h',     // minimum 1-hour TWAP
};
// User can override with explicit acknowledgment
```

---

### 1.2 N-Block Confirmation (Two-Phase Trigger)

A mechanism that requires a condition to remain true for N consecutive blocks before the envelope can fire.

#### 1.2.1 EnvelopeRegistry State Extension

```solidity
// New state in EnvelopeRegistry
mapping(bytes32 envelopeHash => uint256 conditionEnteredBlock) public conditionEnteredAt;
mapping(bytes32 envelopeHash => address firstKeeper) public conditionEnteredBy;
```

#### 1.2.2 Envelope Struct Extension

```solidity
struct Envelope {
    // ... existing fields ...
    uint32 confirmationBlocks;    // 0 = immediate trigger (no confirmation), max 100
    uint256 monitoringRewardWei;  // reward paid to keeper who submits conditionEntered
    // monitoringRewardWei is deducted from keeperRewardBps at trigger time
}
```

#### 1.2.3 Two-Phase Interface

```solidity
interface IEnvelopeRegistry {
    // ... existing functions ...

    /// @notice Phase 1: Record that condition became true (earns monitoring reward)
    /// @param envelopeHash   Hash of the registered envelope
    /// @param conditions     Revealed conditions preimage
    /// @param conditionProof Merkle proof that conditions satisfy conditionsHash
    function recordConditionEntered(
        bytes32 envelopeHash,
        Conditions calldata conditions,
        ConditionProof calldata conditionProof
    ) external;

    /// @notice Phase 2: Trigger envelope after confirmation window
    ///         Can only be called if confirmationBlocks have passed since conditionEntered
    ///         Reverts if condition became false during confirmation window
    function triggerAfterConfirmation(
        bytes32 envelopeHash,
        Conditions calldata conditions,
        Intent calldata intent
    ) external;

    /// @notice Reset confirmation if condition became false during window
    ///         Any address can call — if condition is false, resets conditionEnteredAt
    function resetConditionIfFalse(
        bytes32 envelopeHash,
        Conditions calldata conditions
    ) external;

    // --- Events ---
    event ConditionEntered(bytes32 indexed envelopeHash, uint256 blockNumber, address keeper);
    event ConditionReset(bytes32 indexed envelopeHash, uint256 blockNumber);
}
```

#### 1.2.4 Trigger Flow with N-Block Confirmation

```
Phase 1 (any block when condition first becomes true):
  Keeper calls recordConditionEntered(envelopeHash, conditions, proof)
    → verifies conditions hash matches commitment
    → verifies condition is currently true via oracle
    → stores conditionEnteredAt[envelopeHash] = block.number
    → stores conditionEnteredBy[envelopeHash] = msg.sender
    → pays monitoringRewardWei to msg.sender
    → emits ConditionEntered

Phase 1.5 (optional, if condition becomes false during window):
  Any party calls resetConditionIfFalse(envelopeHash, conditions)
    → verifies condition is currently false
    → clears conditionEnteredAt[envelopeHash]
    → emits ConditionReset
    → (no penalty — the Phase 1 keeper earned their fee legitimately)

Phase 2 (after confirmationBlocks have elapsed):
  Keeper calls triggerAfterConfirmation(envelopeHash, conditions, intent)
    → verifies conditionEnteredAt[envelopeHash] != 0
    → verifies block.number >= conditionEnteredAt[envelopeHash] + confirmationBlocks
    → verifies condition is STILL true (re-checks oracle)
    → verifies intent matches intentCommitment
    → forwards to CapabilityKernel.executeIntent(...)
    → pays (keeperReward - monitoringReward) to msg.sender
```

#### 1.2.5 Combined TWAP + Confirmation Example

```typescript
const envelope = await sdk.createEnvelope({
  positionCommitment: ethPosition.hash,
  conditionTree: sdk.conditionTree.twap({
    baseToken: 'ETH', quoteToken: 'USD',
    window: '15m', threshold: parseUnits('1800', 8), op: 'LESS_THAN'
  }),
  triggerIntent: sellIntent,
  confirmationBlocks: 10,     // ~20 seconds on Base after TWAP check
  monitoringRewardWei: parseEther('0.0001'),  // ~$0.25 on Base
  keeperRewardBps: 50,
  expiry: Date.now() / 1000 + 90 * 86400,
});
// This envelope requires:
// 1. ETH 15-minute TWAP below $1,800 (manipulation resistant)
// 2. Condition confirmed for 10 consecutive blocks (noise resistant)
```

---

## Extension 2: Chained Envelopes (Strategy Graphs)

### 2.1 Data Structures

```solidity
struct Envelope {
    // ... existing fields ...
    bytes32 nextEnvelopeCommitment;  // keccak256(abi.encode(nextEnvelopeSpec))
                                      // bytes32(0) if no chained envelope
}

// Specification for the next envelope in the chain
// Committed at registration time; revealed when parent fires
struct NextEnvelopeSpec {
    Envelope envelope;
    Capability capability;       // capability authorizing the next envelope
    bytes capSig;                // issuer signature over capability
    bytes intentSig;             // grantee signature over trigger intent
    // Note: positionCommitment is NOT included — it's the output of the parent
    //       The next envelope's positionCommitment is computed at trigger time
    //       from the parent's output salt
    bytes32 outputSaltCommitment; // keccak256(outputSalt) — salt for next position
}
```

### 2.2 Modified Trigger Flow

```solidity
function trigger(
    bytes32 envelopeHash,
    Conditions calldata conditions,
    Intent calldata intent,
    NextEnvelopeSpec calldata nextSpec  // empty if no chained envelope
) external {
    // ... existing trigger verification ...
    
    // Execute the intent via CapabilityKernel
    bytes32 outputPositionHash = capabilityKernel.executeIntent(
        position, capability, intent, capSig, intentSig
    );
    
    // If this envelope has a next envelope, register it
    if (envelope.nextEnvelopeCommitment != bytes32(0)) {
        // Verify the revealed nextSpec matches the committed hash
        require(
            keccak256(abi.encode(nextSpec)) == envelope.nextEnvelopeCommitment,
            "NEXT_ENVELOPE_MISMATCH"
        );
        
        // Inject the output position as the next envelope's position commitment
        Envelope memory nextEnvelope = nextSpec.envelope;
        nextEnvelope.positionCommitment = outputPositionHash;
        
        // Register the next envelope atomically
        bytes32 nextHash = _register(nextEnvelope, nextSpec.capability, nextSpec.capSig, nextSpec.intentSig);
        
        // Encumber the output position immediately
        vault.encumber(outputPositionHash);
        
        // Pay keeper a registration bonus for handling the chain
        uint256 registrationBonus = CHAIN_REGISTRATION_FEE_WEI;
        _payKeeper(msg.sender, registrationBonus);
        
        emit EnvelopeChained(envelopeHash, nextHash, outputPositionHash);
    }
}
```

### 2.3 Graph Safety: Cycle Detection

At registration time, the registry validates that the chain does not create a runaway loop without an exit condition:

```solidity
function _validateChainDepth(
    bytes32 envelopeHash,
    uint256 currentDepth
) internal view {
    require(currentDepth <= MAX_CHAIN_DEPTH, "CHAIN_TOO_DEEP");
    // MAX_CHAIN_DEPTH = 16 (governance-adjustable, max 32)
    
    Envelope memory envelope = envelopes[envelopeHash];
    if (envelope.nextEnvelopeCommitment != bytes32(0)) {
        // Can't fully validate chain at registration because next envelopes
        // aren't registered yet — depth is enforced at trigger time
    }
}

// At trigger time: verify chain depth hasn't exceeded maximum
mapping(bytes32 envelopeHash => uint256 chainDepth) public envelopeChainDepth;
```

### 2.4 Cancellation Propagation

Cancelling a parent envelope cascades to cancel all pre-committed descendants:

```solidity
// The chain of nextEnvelopeCommitment hashes is stored for cancellation lookup
mapping(bytes32 envelopeHash => bytes32[] descendants) private envelopeDescendants;

function cancel(bytes32 envelopeHash) external {
    require(
        envelopes[envelopeHash].positionOwner == msg.sender,
        "NOT_OWNER"
    );
    
    // Cancel this envelope
    _cancel(envelopeHash);
    
    // Cancel all registered descendants
    bytes32[] memory descendants = envelopeDescendants[envelopeHash];
    for (uint256 i = 0; i < descendants.length; i++) {
        if (envelopes[descendants[i]].exists) {
            _cancel(descendants[i]);
        }
    }
    
    emit EnvelopeCancelled(envelopeHash);
    emit DescendantsCancelled(envelopeHash, descendants.length);
}
```

### 2.5 SDK: Building Strategy Graphs

```typescript
// Build a 3-stage strategy graph
const graph = sdk.strategyGraph.create();

// Stage 1: ETH drops → sell to USDC
graph.add({
  id: 'exit',
  positionCommitment: ethPosition.hash,
  conditionTree: sdk.conditionTree.price('ETH/USD', 'LESS_THAN', 2000),
  triggerIntent: sdk.intent.sell(ethPosition, USDC),
  keeperRewardBps: 40,
});

// Stage 2: USDC idle 7 days → deploy to Aave
graph.add({
  id: 'deploy-yield',
  // positionCommitment: auto-computed from stage 1 output
  conditionTree: sdk.conditionTree.time({ 
    type: 'IDLE_SINCE_CREATION', 
    minIdleSecs: 7 * 86400 
  }),
  triggerIntent: sdk.intent.aaveDeposit(USDC),
  keeperRewardBps: 20,
  after: 'exit',  // links to previous stage
});

// Stage 3: Aave yield drops or health stress → withdraw and rebuy ETH  
graph.add({
  id: 'reentry',
  conditionTree: sdk.conditionTree.or(
    sdk.conditionTree.onChain({ 
      protocol: 'aave-v3', fn: 'getSupplyAPY', asset: 'USDC',
      op: 'LESS_THAN', threshold: parseUnits('3', 6)  // < 3% APY
    }),
    sdk.conditionTree.price('ETH/USD', 'LESS_THAN', 1600)  // deep dip rebuy
  ),
  triggerIntent: sdk.intent.aaveWithdrawAndSwap(USDC, ETH),
  keeperRewardBps: 40,
  after: 'deploy-yield',
});

// Register the entire graph in one transaction
const { envelopeHashes } = await sdk.strategyGraph.register(graph, capability, capSig);
// Returns all envelope hashes; first envelope is active, rest pre-committed
```

---

## Extension 3: Sustained Conditions (Regime Detection)

### 3.1 SustainedLeaf Data Structure

```solidity
// Wraps any leaf type — the inner condition must remain true for minimumDurationSecs
struct SustainedLeaf {
    ConditionNodeType innerType;   // LEAF_PRICE | LEAF_TIME | LEAF_VOLATILITY | LEAF_ONCHAIN
    bytes innerLeaf;               // abi.encoded inner leaf
    uint32 minimumDurationSecs;    // minimum continuous true duration (max 30 days)
    uint32 samplingIntervalSecs;   // how often keepers sample (affects monitoring fee)
}
```

### 3.2 Sustained Condition Registry State

```solidity
struct SustainedConditionState {
    uint256 conditionEnteredAt;   // timestamp when condition became true (0 if not entered)
    uint256 lastSampledAt;        // timestamp of most recent keeper sample
    bool    isCurrentlyTrue;      // cached oracle state (updated by keeper samples)
}

mapping(bytes32 envelopeHash => SustainedConditionState) public sustainedStates;
```

### 3.3 Three-Phase Protocol for Sustained Conditions

```solidity
interface IEnvelopeRegistry {

    /// @notice Phase 1: Keeper samples the condition (called at samplingIntervalSecs intervals)
    ///         Earns sampling fee if condition state changed
    ///         Earns entry fee if condition just became true
    function sampleSustainedCondition(
        bytes32 envelopeHash,
        Conditions calldata conditions,
        ConditionProof calldata conditionProof
    ) external returns (bool conditionTrue, bool justEntered);

    /// @notice Phase 2: Trigger sustained envelope after minimumDurationSecs
    ///         Reverts if condition was false at any point during the minimum duration
    function triggerSustained(
        bytes32 envelopeHash,
        Conditions calldata conditions,
        Intent calldata intent
    ) external;

    // Events
    event SustainedConditionEntered(bytes32 indexed envelopeHash, uint256 timestamp);
    event SustainedConditionExited(bytes32 indexed envelopeHash, uint256 duration);
    event SustainedConditionTriggered(bytes32 indexed envelopeHash, uint256 totalDuration);
}
```

### 3.4 Keeper Fee Structure for Sustained Conditions

```solidity
struct SustainedKeeperFees {
    uint256 samplingFeeWei;     // paid per sample call (covers gas + small margin)
    uint256 entryBonusWei;      // extra fee when keeper first detects condition entering
    uint256 triggerRewardBps;   // main reward on final trigger (same as standard envelopes)
}

// Fee sourcing: all fees deducted from the keeperReward at trigger time
// If envelope expires without triggering, sampling fees are paid from a
// pre-deposited fee buffer (required at envelope registration for sustained envelopes)
```

### 3.5 Interruption Handling

If a keeper samples and finds the condition is false during the minimum duration window:

```solidity
function sampleSustainedCondition(...) external returns (bool conditionTrue, bool justEntered) {
    SustainedConditionState storage state = sustainedStates[envelopeHash];
    
    bool currentlyTrue = evaluateConditionTree(envelopeHash, conditions, conditionProof);
    
    if (!currentlyTrue && state.isCurrentlyTrue) {
        // Condition just became false — reset the entered timestamp
        state.conditionEnteredAt = 0;
        state.isCurrentlyTrue = false;
        emit SustainedConditionExited(
            envelopeHash,
            block.timestamp - state.conditionEnteredAt
        );
        // Pay sampling fee anyway — keeper did correct work
        _payKeeper(msg.sender, fees.samplingFeeWei);
        return (false, false);
    }
    
    if (currentlyTrue && !state.isCurrentlyTrue) {
        // Condition just became true — record entry
        state.conditionEnteredAt = block.timestamp;
        state.isCurrentlyTrue = true;
        _payKeeper(msg.sender, fees.samplingFeeWei + fees.entryBonusWei);
        emit SustainedConditionEntered(envelopeHash, block.timestamp);
        return (true, true);
    }
    
    // Condition unchanged
    state.lastSampledAt = block.timestamp;
    if (block.timestamp - state.lastSampledAt >= envelope.samplingIntervalSecs) {
        _payKeeper(msg.sender, fees.samplingFeeWei);
    }
    return (currentlyTrue, false);
}
```

### 3.6 SDK Integration

```typescript
// Create a sustained condition envelope
const envelope = await sdk.createEnvelope({
  positionCommitment: aaveUSDCPosition.hash,
  conditionTree: sdk.conditionTree.sustained({
    inner: sdk.conditionTree.onChain({
      protocol: 'aave-v3',
      fn: 'getUtilizationRate',
      asset: 'USDC',
      op: 'GREATER_THAN',
      threshold: parseUnits('0.92', 18)   // > 92% utilization
    }),
    minimumDuration: '30m',    // must be above 92% for 30 continuous minutes
    samplingInterval: '2m',    // keepers check every 2 minutes
  }),
  triggerIntent: sdk.intent.aaveWithdraw(USDC),
  keeperFees: {
    samplingFeeWei: parseEther('0.00005'),   // ~$0.13 per sample on Base
    entryBonusWei: parseEther('0.0002'),      // ~$0.50 entry detection bonus
  },
  keeperRewardBps: 30,
  expiry: Date.now() / 1000 + 180 * 86400,
});
```

---

## Extension 4: Strategy NFT Marketplace

### 4.1 StrategyNFT Contract

```solidity
/// @title StrategyNFT
/// @notice ERC-1155 token representing a reusable condition tree strategy template
contract StrategyNFT is ERC1155, Ownable {
    
    struct StrategyTemplate {
        bytes32 conditionTreeRoot;    // merkle root of the condition tree
        bytes32 intentTemplateHash;   // hash of parameterized intent template
        address creator;              // strategy creator address
        uint256 licenseFeeBps;        // basis points of execution value paid to creator
        uint256 flatFeeWei;           // optional flat fee per application
        string  metadataURI;          // IPFS URI for strategy description + backtest
        uint256 totalApplications;    // number of times applied (live counter)
        uint256 totalExecutions;      // number of times triggered (live counter)
        bool    active;               // creator can deactivate
    }
    
    mapping(uint256 tokenId => StrategyTemplate) public strategies;
    uint256 public nextTokenId;
    
    // Protocol fee: 10% of all license fees
    uint256 public constant PROTOCOL_FEE_BPS = 1000;
    address public protocolFeeRecipient;

    function mintStrategy(
        bytes32 conditionTreeRoot,
        bytes32 intentTemplateHash,
        uint256 licenseFeeBps,      // max 100 bps (1%)
        uint256 flatFeeWei,
        string calldata metadataURI
    ) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        strategies[tokenId] = StrategyTemplate({
            conditionTreeRoot: conditionTreeRoot,
            intentTemplateHash: intentTemplateHash,
            creator: msg.sender,
            licenseFeeBps: licenseFeeBps,
            flatFeeWei: flatFeeWei,
            metadataURI: metadataURI,
            totalApplications: 0,
            totalExecutions: 0,
            active: true
        });
        _mint(msg.sender, tokenId, 1, "");
        emit StrategyMinted(tokenId, msg.sender, conditionTreeRoot);
    }
}
```

### 4.2 Strategy Application: Binding a Template to a User Position

```solidity
/// @notice Apply a strategy template to a user's position
/// @param strategyTokenId  The NFT representing the strategy
/// @param positionCommitment  User's vault position to apply strategy to
/// @param intentParams  User-specific parameters (minReturn, expiry, keeper reward)
/// @param capability  User's capability authorizing the agent
/// @param capSig  Signature over capability
/// @param intentSig  Signature over parameterized intent
function applyStrategy(
    uint256 strategyTokenId,
    bytes32 positionCommitment,
    IntentParams calldata intentParams,
    Capability calldata capability,
    bytes calldata capSig,
    bytes calldata intentSig
) external payable returns (bytes32 envelopeHash) {
    StrategyTemplate storage template = strategies[strategyTokenId];
    require(template.active, "STRATEGY_INACTIVE");
    
    // Collect flat fee if required
    require(msg.value >= template.flatFeeWei, "INSUFFICIENT_LICENSE_FEE");
    
    // Distribute flat fee: 90% to creator, 10% to protocol
    uint256 protocolShare = template.flatFeeWei * PROTOCOL_FEE_BPS / 10000;
    _pay(template.creator, template.flatFeeWei - protocolShare);
    _pay(protocolFeeRecipient, protocolShare);
    
    // Build envelope using template's condition tree root
    Envelope memory envelope = Envelope({
        positionCommitment: positionCommitment,
        conditionsHash: template.conditionTreeRoot,
        intentCommitment: _buildIntentCommitment(template.intentTemplateHash, intentParams),
        capabilityHash: keccak256(abi.encode(capability)),
        expiry: intentParams.expiry,
        keeperRewardBps: intentParams.keeperRewardBps,
        strategyTokenId: strategyTokenId  // links execution back to NFT for royalties
    });
    
    envelopeHash = envelopeRegistry.register(envelope, capability, capSig, intentSig);
    template.totalApplications++;
    
    emit StrategyApplied(strategyTokenId, envelopeHash, msg.sender);
}
```

### 4.3 Execution Royalty Distribution

When an envelope created from a strategy template is triggered, the royalty is distributed atomically with execution:

```solidity
// In EnvelopeRegistry.trigger():
function trigger(bytes32 envelopeHash, ...) external {
    Envelope memory envelope = envelopes[envelopeHash];
    
    // ... standard execution ...
    
    uint256 outputAmount = executeIntent(...);
    uint256 keeperReward = outputAmount * envelope.keeperRewardBps / 10000;
    
    // If this envelope was created from a strategy NFT, pay license royalty
    if (envelope.strategyTokenId != 0) {
        StrategyTemplate memory template = strategyNFT.strategies(envelope.strategyTokenId);
        uint256 royalty = outputAmount * template.licenseFeeBps / 10000;
        uint256 protocolRoyaltyShare = royalty * PROTOCOL_FEE_BPS / 10000;
        
        _pay(template.creator, royalty - protocolRoyaltyShare);
        _pay(protocolFeeRecipient, protocolRoyaltyShare);
        
        strategyNFT.recordExecution(envelope.strategyTokenId);
    }
    
    _pay(msg.sender, keeperReward);
}
```

### 4.4 Strategy Reputation: On-Chain Statistics

```solidity
struct StrategyExecutionStats {
    uint256 totalExecutions;
    uint256 totalVolumeUSD;        // sum of all execution amountIn values
    uint256 averageFillTimeSecs;   // average time from condition met to execution
    uint256 successfulFills;       // executions that met minReturn floor
    uint256 missedFills;           // executions that reverted at minReturn check
    uint256 averageSlippageBps;    // average (minReturn - actualReturn) / minReturn
    uint256 totalUsersApplied;     // unique users who have applied this strategy
}

mapping(uint256 tokenId => StrategyExecutionStats) public executionStats;
```

### 4.5 SDK: Strategy Marketplace

```typescript
// Browse strategies
const strategies = await sdk.marketplace.list({
  category: 'risk-management',
  minExecutions: 50,
  maxSlippageBps: 30,
  sortBy: 'fillRate',
});

// Get detailed stats for a strategy
const stats = await sdk.marketplace.stats(strategyTokenId);
// {
//   totalExecutions: 1247,
//   fillRate: 0.997,
//   averageFillTimeSecs: 42,
//   averageSlippageBps: 12,
//   totalUsers: 89,
//   backtestResults: { ... }  // from IPFS metadata
// }

// Apply a strategy to your position
const envelope = await sdk.marketplace.apply({
  strategyTokenId,
  positionCommitment: ethPosition.hash,
  intentParams: {
    minReturn: parseEther('0.95'),   // user sets their own floor
    expiry: Date.now() / 1000 + 90 * 86400,
    keeperRewardBps: 40,
  },
  capability,
  capSig,
  agentKey,
});

// Mint your own strategy
const tokenId = await sdk.marketplace.mint({
  conditionTree: myTree,
  intentTemplate: myTemplate,
  licenseFeeBps: 2,           // 2 bps of execution value per trigger
  flatFeeWei: 0,
  description: 'Volatility-aware ETH stop-loss with cascade de-risking',
  backtestResults: backtestData,  // uploaded to IPFS automatically
});
```

---

## Extension 5: Synthetic Options (Specification Layer)

This extension requires no new smart contracts. It is a specification of how existing condition tree envelopes map to standard options structures, enabling the SDK to generate them from options-style parameters.

### 5.1 Options-Style SDK Interface

```typescript
// Instead of building condition trees manually, express as options
const put = await sdk.options.put({
  underlying: 'ETH',
  strike: parseUnits('1800', 8),         // $1,800
  expiry: Date.now() / 1000 + 30 * 86400,
  positionCommitment: ethPosition.hash,
  settlementToken: USDC,
  minReturn: parseUnits('1750', 6),       // $1,750 floor on settlement
  keeperRewardBps: 40,
  // Generates: PriceLeaf(ETH/USD < 1800) + sell intent
});

const collar = await sdk.options.collar({
  underlying: 'ETH',
  lowerStrike: parseUnits('1600', 8),    // put floor
  upperStrike: parseUnits('2800', 8),    // call ceiling
  expiry: Date.now() / 1000 + 30 * 86400,
  positionCommitment: ethPosition.hash,
  // Generates: two envelopes on split positions
});

const straddle = await sdk.options.straddle({
  underlying: 'ETH',
  lowerStrike: parseUnits('1600', 8),
  upperStrike: parseUnits('2800', 8),
  // OR(price < 1600, price > 2800) condition tree
});

const asianPut = await sdk.options.asianPut({
  underlying: 'ETH',
  strike: parseUnits('1800', 8),
  averagingWindow: '7d',                  // TWAP leaf with 7-day window
  // TWAPLeaf(ETH 7d TWAP < 1800)
});

const barrierOption = await sdk.options.barrierPut({
  underlying: 'ETH',
  strike: parseUnits('1800', 8),
  barrier: {
    type: 'knock-in',
    condition: sdk.conditionTree.volatility('ETH', '24h', 'GREATER_THAN', 0.60),
  },
  // ConditionalCapability + PriceLeaf
});
```

### 5.2 Settlement Guarantee Spec

Every options-style envelope carries the following guarantees by default when created via `sdk.options.*`:

```typescript
const OPTIONS_DEFAULTS = {
  // Minimum TWAP window based on position size (manipulation resistance)
  twapWindow: 'auto',          // SDK selects based on position size
  
  // N-block confirmation (noise resistance)
  confirmationBlocks: 5,        // ~10 seconds on Base
  
  // minReturn floor set to strike × 0.995 (0.5% below strike)
  // User can tighten this
  minReturnFloor: 0.995,
  
  // MEV protection via Flashbots Protect (same as all envelopes)
  mevProtection: true,
};
```

### 5.3 Options Analytics in SDK

```typescript
// Simulate option payoff
const payoff = await sdk.options.simulate(put, {
  scenarios: [
    { ethPrice: 2000, vol: 0.4 },
    { ethPrice: 1800, vol: 0.7 },
    { ethPrice: 1500, vol: 1.2 },
  ]
});
// Returns: would have triggered at $1,800 scenario, executed at $1,797 (0.17% slippage)

// Estimate "premium" (keeper reward cost + encumbrance opportunity cost)
const impliedCost = sdk.options.impliedCost(put, {
  ethPrice: 1950,
  vol: 0.65,
  riskFreeRate: 0.05,
  daysToExpiry: 30,
});
// Returns: estimated equivalent Black-Scholes premium for comparison
```

---

## Open Design Questions

| # | Question | Options | Recommendation |
|---|---|---|---|
| 1 | TWAP oracle: Uniswap V3 or custom? | UniV3 (decentralized, existing) / Custom (flexible) | UniV3 as primary, custom as secondary |
| 2 | Max chain depth for strategy graphs | 8 / 16 / 32 | 16 for v1 |
| 3 | Sustained condition fee buffer: pre-deposited or deducted? | Pre-deposit at registration / Deduct from output | Pre-deposit for predictability |
| 4 | Strategy NFT standard: ERC-721 or ERC-1155? | 721 (unique) / 1155 (fungible copies) | 1155 — multiple users can hold the same strategy |
| 5 | License fee cap: 1% or 5%? | 1% (user-protective) / 5% (creator-attractive) | 1% with creator whitelist for higher rates |
| 6 | Options interface: separate contract or SDK-only? | Separate contract (on-chain type) / SDK (off-chain sugar) | SDK-only initially; formalize later |
| 7 | N-block confirmation: global minimum or per-envelope? | Global minimum (simpler) / Per-envelope (flexible) | Per-envelope with SDK-enforced minimums by size |

---

## Gas Estimates (Base L2)

| Operation | Estimated Gas | Estimated USD |
|---|---|---|
| Standard envelope trigger (single leaf) | ~80k | ~$0.02 |
| TWAP leaf evaluation (+1 oracle call) | +15k | +$0.004 |
| N-block Phase 1 (conditionEntered) | ~40k | ~$0.01 |
| N-block Phase 2 (trigger after confirmation) | ~85k | ~$0.02 |
| Sustained condition sample | ~35k | ~$0.009 |
| Chained envelope registration (at trigger) | +50k | +$0.013 |
| Strategy NFT application | ~120k | ~$0.03 |
| Strategy NFT royalty distribution (at trigger) | +20k | +$0.005 |

All estimates on Base at 0.001 gwei base fee. Total cost for a full strategy graph trigger with TWAP + chained registration: ~$0.07. Negligible relative to position sizes this protocol targets.
