// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IReceiptAccumulator
/// @notice Interface for the on-chain receipt accumulator that anchors Circuit 1 proofs.
///
/// The accumulator is the on-chain state that transforms Circuit 1 from
/// "uncorroborated selective disclosure" into a full anti-fabrication proof.
///
/// Without an accumulator: the agent picks which receipts to include in its proof.
///   → Agent can cherry-pick successful repayments and omit defaults.
///   → Credit credential is untrustworthy.
///
/// With an accumulator: every receipt is committed to a rolling hash chain the moment
/// it is executed. The current root is publicly readable. Circuit 1 proves that N
/// receipts hash to the current root — if any receipt is omitted, the root won't match.
///   → Agent must prove ALL receipts up to index N, or the root check fails.
///   → Cherry-picking is cryptographically impossible.
///
/// Called exclusively by CapabilityKernel at the end of every successful executeIntent.

interface IReceiptAccumulator {

    /// @notice Accumulate a receipt from a completed intent execution.
    ///
    /// @param capabilityHash  keccak256 hash of the authorizing Capability struct.
    ///                        Used to bucket receipts per agent identity.
    /// @param receiptHash     keccak256(nullifier, positionIn, positionOut) — the kernel's receipt.
    /// @param nullifier       keccak256(intent.nonce, positionCommitment) — prevents replay.
    /// @param adapter         The adapter used in this execution.
    /// @param amountIn        Input token amount (the position amount spent).
    /// @param amountOut       Gross output amount returned by the adapter.
    function accumulate(
        bytes32 capabilityHash,
        bytes32 receiptHash,
        bytes32 nullifier,
        address adapter,
        uint256 amountIn,
        uint256 amountOut
    ) external;

    /// @notice Returns the current rolling root for a capability.
    ///         Equivalent to rootAtIndex(capabilityHash, receiptCount(capabilityHash)).
    function rollingRoot(bytes32 capabilityHash) external view returns (bytes32);

    /// @notice Returns the rolling root after exactly `index` receipts have been accumulated
    ///         across ALL adapters for this capability (the global per-capability chain).
    ///
    ///   index == 0                        → bytes32(0)  (initial root, before any receipts)
    ///   index == receiptCount(cap)        → same value as rollingRoot(cap)
    ///   0 < index < receiptCount(cap)     → root after receipt[index-1] was committed
    ///
    /// This enables partial proofs against the global chain.
    function rootAtIndex(bytes32 capabilityHash, uint256 index) external view returns (bytes32);

    /// @notice Returns the per-adapter rolling root after exactly `index` receipts through
    ///         `adapter` have been accumulated (H-3: adapter-filtered proof support).
    ///
    ///   index == 0                                  → bytes32(0)
    ///   index == adapterReceiptCount(cap, adapter)  → current adapter root
    ///
    /// Use this as the Circuit 1 `accumulator_root` public input when `adapterFilter` is set.
    /// The circuit proves that exactly N sequential receipts — all through `adapter` — hash
    /// to this root.  Because the root is adapter-scoped, interleaved receipts from other
    /// adapters do not affect it, solving the adapter-interleaving proof failure (H-3).
    function adapterRootAtIndex(bytes32 capabilityHash, address adapter, uint256 index)
        external view returns (bytes32);

    /// @notice Returns the total number of accumulated receipts for a capability.
    function receiptCount(bytes32 capabilityHash) external view returns (uint256);

    /// @notice Returns the number of receipts through a specific adapter for a capability.
    ///         Clawloan uses this to count only ClawloanRepayAdapter receipts.
    function adapterReceiptCount(bytes32 capabilityHash, address adapter)
        external view returns (uint256);

    /// @notice Returns the ordered receipt hash array for off-chain Circuit 1 witness generation.
    function getReceiptHashes(bytes32 capabilityHash) external view returns (bytes32[] memory);

    /// @notice Returns the ordered nullifier array for off-chain Circuit 1 witness generation.
    function getNullifiers(bytes32 capabilityHash) external view returns (bytes32[] memory);

    /// @notice Returns the ordered receipt hash array filtered to a specific adapter,
    ///         for off-chain adapter-filtered Circuit 1 witness generation (H-3).
    function getAdapterReceiptHashes(bytes32 capabilityHash, address adapter)
        external view returns (bytes32[] memory);

    /// @notice Returns the ordered nullifier array filtered to a specific adapter (H-3).
    function getAdapterNullifiers(bytes32 capabilityHash, address adapter)
        external view returns (bytes32[] memory);
}
