// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Types
/// @notice Shared data structures for the Stateless Agent Protocol.

library Types {

    // ─────────────────────────────────────────────────────────────────────────
    // Position
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A user's asset position stored as a hash commitment in SingletonVault.
    /// @dev positionHash = keccak256(abi.encode(position)).
    ///      The vault stores no balance mapping — only whether this hash exists.
    struct Position {
        address owner;   // address that controls capability issuance over this position
        address asset;   // ERC-20 token address
        uint256 amount;  // actual amount received by vault (post fee-on-transfer)
        bytes32 salt;    // user-chosen entropy — prevents commitment collision
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Capability
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Constraints bounding what an agent is permitted to do within a capability.
    struct Constraints {
        uint256 maxSpendPerPeriod;   // max input token amount per period (0 = unlimited)
        uint256 periodDuration;      // period length in seconds (0 = no period enforcement)
        uint256 minReturnBps;        // minimum output as basis points of input (e.g. 9800 = 98% min return)
                                     // 0 = no constraint. Kernel enforces: amountOut >= amountIn * minReturnBps / 10000
                                     // Prevents agent from setting intent.minReturn to dust on a large position.
        address[] allowedAdapters;   // empty = all registered adapters allowed
        address[] allowedTokensIn;   // empty = any token allowed as input
        address[] allowedTokensOut;  // empty = any token allowed as output
    }

    /// @notice Off-chain authorization token granting an agent key scoped authority.
    ///
    /// Delegation chains (A → B → C):
    ///   - Root delegation (user → agent): set parentCapabilityHash = bytes32(0), delegationDepth = 0.
    ///   - Sub-delegation (agent → sub-agent): set parentCapabilityHash = hash of parent capability,
    ///     delegationDepth = parent.delegationDepth + 1.
    ///   - Sub-delegated capabilities must have constraints that are a strict subset of the parent.
    ///   - CapabilityKernel enforces delegationDepth == 0 in Phase 1.
    ///     Full chain verification (Phase 2) will accept delegationDepth > 0 with parent proofs.
    ///
    /// @dev Signed by `issuer` as EIP-712 typed data. Submitted alongside an Intent — never independently.
    struct Capability {
        address issuer;                // user address — must match position.owner (depth=0) or parent.grantee (depth>0)
        address grantee;               // agent key receiving authority
        bytes32 scope;                 // keccak256("vault.spend") | keccak256("envelope.manage")
        uint256 expiry;                // unix timestamp after which capability is invalid
        bytes32 nonce;                 // unique per-capability — used for revocation
        Constraints constraints;
        bytes32 parentCapabilityHash;  // 0x0 for root, hash of parent cap for sub-delegation
        uint8   delegationDepth;       // 0 = user→agent, 1 = agent→subagent, etc.
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Intent
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Off-chain execution instruction signed by the agent (capability.grantee).
    ///
    /// MEV protection:
    ///   submitter — the only address allowed to call executeIntent with this intent.
    ///   Set to address(0) to allow any solver (permissionless, for Phase 3+).
    ///   Set to a specific solver address to prevent frontrunning (recommended for Phase 1).
    ///
    /// Solver fee:
    ///   solverFeeBps — basis points of gross output paid to msg.sender (the solver).
    ///   e.g. 10 = 0.1%. Max 100 (1%). Deducted from amountOut before vault commitment.
    ///   minReturn is the gross floor BEFORE solver fee deduction.
    ///
    struct Intent {
        bytes32 positionCommitment; // keccak256(abi.encode(Position)) being spent
        bytes32 capabilityHash;     // keccak256 of the authorizing Capability
        address adapter;            // registered adapter to execute through
        bytes   adapterData;        // abi-encoded parameters forwarded to adapter
        uint256 minReturn;          // minimum gross output from adapter (hard floor, pre-fee)
        uint256 deadline;           // unix timestamp — revert if exceeded
        bytes32 nonce;              // unique per-intent — nullifier seed
        address outputToken;        // expected output ERC-20 token
        address returnTo;           // where to create output position (vault address)
        address submitter;          // address allowed to submit (address(0) = anyone)
        uint16  solverFeeBps;       // solver fee in basis points (max 100 = 1%)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Envelope
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Pre-committed conditional execution instruction.
    ///
    /// Keeper reward model:
    ///   - keeperRewardBps:    percentage of output amount (max 500 = 5%)
    ///   - minKeeperRewardWei: absolute minimum in wei of output token (prevents unprofitable triggers)
    ///   Keeper receives max(minKeeperRewardWei, outputAmount * keeperRewardBps / 10000).
    ///
    struct Envelope {
        bytes32 positionCommitment; // position this envelope encumbers
        bytes32 conditionsHash;     // keccak256(abi.encode(Conditions)) — revealed only at trigger
        bytes32 intentCommitment;   // keccak256(abi.encode(Intent)) — revealed only at trigger
        bytes32 capabilityHash;     // capability that authorized envelope creation
        uint256 expiry;             // envelope auto-expires if never triggered
        uint16  keeperRewardBps;    // percentage reward (max 500)
        uint128 minKeeperRewardWei; // absolute minimum reward in output token's smallest unit
    }

    enum ComparisonOp { LESS_THAN, GREATER_THAN, EQUAL }

    /// @notice Boolean operator used to combine a primary and secondary oracle condition.
    enum LogicOp { AND, OR }

    /// @notice Trigger conditions committed inside an Envelope.
    ///
    /// Single condition:
    ///   Set secondaryOracle = address(0). Only the primary oracle/price/op is evaluated.
    ///
    /// Compound condition:
    ///   Set secondaryOracle to a valid Chainlink-compatible feed.
    ///   logicOp = OR  → fires when EITHER condition is met (e.g. deadline OR health factor drops).
    ///   logicOp = AND → fires only when BOTH conditions are met simultaneously.
    struct Conditions {
        address priceOracle;   // Chainlink-compatible feed (latestRoundData, int256 answer)
        address baseToken;     // informational — token whose price is checked
        address quoteToken;    // informational
        uint256 triggerPrice;  // price threshold (scaled to oracle decimals, e.g. 1800e8)
        ComparisonOp op;
        // ── Compound condition (optional) ──────────────────────────────────────
        // If secondaryOracle == address(0), the secondary fields are ignored entirely.
        address secondaryOracle;         // second Chainlink-compatible feed; address(0) = disabled
        uint256 secondaryTriggerPrice;   // threshold for the secondary oracle
        ComparisonOp secondaryOp;        // comparison for the secondary oracle
        LogicOp logicOp;                 // how to combine primary and secondary: AND or OR
    }
}
