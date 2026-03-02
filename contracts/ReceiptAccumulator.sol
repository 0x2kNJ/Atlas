// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IReceiptAccumulator} from "./interfaces/IReceiptAccumulator.sol";

/// @title ReceiptAccumulator
/// @notice On-chain anchor for Circuit 1 (Selective Disclosure Proof) anti-fabrication guarantees.
///
/// ─── The Problem This Solves ────────────────────────────────────────────────
///
/// Without this contract, an agent proving its Clawloan repayment history with Circuit 1
/// can cherry-pick which receipts to include. An agent with 10 repayments and 2 defaults
/// could include only the 10 repayments and prove a perfect record. The verifier has no
/// way to know receipts were omitted.
///
/// ─── How It Works ────────────────────────────────────────────────────────────
///
/// Every time CapabilityKernel.executeIntent() succeeds, the kernel calls
/// accumulate() here, appending the receipt to a per-capability rolling hash chain:
///
///   root_0 = bytes32(0)
///   root_i = keccak256(abi.encode(root_{i-1}, i-1, receiptHash_i, nullifier_i, adapter_i))
///            [32] prevRoot | [32] index(uint256) | [32] receiptHash | [32] nullifier | [32] adapter
///            = 160 bytes total — matches the Noir circuit's encode_root_update() exactly.
///
/// IMPORTANT: adapter is included in the hash (C-2 fix — previously the NatDoc omitted it).
/// Any new verifier implementation must include adapter as the fifth field or hashes diverge.
///
/// The rolling root is public on-chain. Circuit 1 takes the N receipt hashes, nullifiers,
/// and adapter addresses as PRIVATE inputs and proves it can recompute the same rolling root:
///
///   If the agent claims N=10 repayments, it must provide all 10 receipts in order.
///   If there are actually 12 receipts (including 2 defaults), it CANNOT produce a proof
///   for N=10 that matches root_12. It would need N=12.
///
///   Proof for N=10 is valid only against root_10 (after exactly 10 receipts).
///   The on-chain root_12 won't match root_10 because receipt 11 and 12 were not included.
///   Therefore, ANY omission of a receipt makes the proof invalid against the current root.
///
/// ─── Data Available for Circuit 1 Witness Generation ────────────────────────
///
/// Off-chain proof generation requires:
///   1. receiptHashes[]   — call getReceiptHashes(capabilityHash)
///   2. nullifiers[]      — call getNullifiers(capabilityHash)
///   3. Current root      — rollingRoot(capabilityHash)
///   4. Receipt metadata  — listen to ReceiptAccumulated events for amountIn/amountOut
///
/// ─── Per-Adapter Counts ──────────────────────────────────────────────────────
///
/// adapterReceiptCount(capabilityHash, adapter) allows Clawloan's CreditVerifier to
/// check: "how many of this agent's proven receipts went through ClawloanRepayAdapter?"
/// Circuit 1 can additionally filter on adapter in its constraint layer.

contract ReceiptAccumulator is Ownable2Step, IReceiptAccumulator {

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Only the CapabilityKernel may call accumulate().
    address public kernel;

    /// @notice Per-capability rolling hash root.
    ///         root_i = keccak256(abi.encode(root_{i-1}, index, receiptHash, nullifier))
    mapping(bytes32 capabilityHash => bytes32 root) private _rollingRoot;

    /// @notice Per-capability total receipt count.
    mapping(bytes32 capabilityHash => uint256 count) private _receiptCount;

    /// @notice Per-capability per-adapter receipt count (filtered credit counting).
    mapping(bytes32 capabilityHash => mapping(address adapter => uint256)) private _adapterCount;

    /// @notice Per-capability ordered receipt hashes (for off-chain witness generation).
    mapping(bytes32 capabilityHash => bytes32[] hashes) private _receiptHashes;

    /// @notice Per-capability ordered nullifiers (for off-chain witness generation).
    mapping(bytes32 capabilityHash => bytes32[] nulls) private _nullifiers;

    /// @notice Per-capability ordered historical roots.
    ///         _historicalRoots[cap][i] = rolling root after receipt at index i has been committed.
    ///         Enables partial Circuit 1 proofs: rootAtIndex(cap, N) = _historicalRoots[cap][N-1].
    mapping(bytes32 capabilityHash => bytes32[] roots) private _historicalRoots;

    // ── H-3: Per-adapter rolling roots ───────────────────────────────────────
    //
    // Problem: the global per-capability rolling root is computed over ALL receipts in
    // chronological order regardless of adapter.  Circuit 1 with adapterFilter requires
    // ALL N proven receipts to match the filter, so if receipts are interleaved between
    // adapters the agent cannot produce a valid adapter-filtered proof even when they
    // have enough receipts of the right type.
    //
    // Fix: maintain a parallel rolling root that chains ONLY receipts for a given adapter.
    // CreditVerifier uses adapterRootAtIndex() as the Circuit 1 public input when
    // adapterFilter is set, eliminating the interleaving constraint.

    /// @notice Per-adapter rolling root (only receipts through that adapter contribute).
    ///         Updated on every accumulate() call for the specific adapter used.
    mapping(bytes32 capabilityHash => mapping(address adapter => bytes32)) private _adapterRollingRoot;

    /// @notice Per-adapter historical roots for partial adapter-filtered proofs.
    ///         _adapterHistoricalRoots[cap][adapter][i] = root after the i-th adapter receipt.
    mapping(bytes32 capabilityHash => mapping(address adapter => bytes32[])) private _adapterHistoricalRoots;

    /// @notice Per-adapter ordered receipt hashes for off-chain witness generation (H-3).
    mapping(bytes32 capabilityHash => mapping(address adapter => bytes32[])) private _adapterReceiptHashes;

    /// @notice Per-adapter ordered nullifiers for off-chain witness generation (H-3).
    mapping(bytes32 capabilityHash => mapping(address adapter => bytes32[])) private _adapterNullifiers;

    /// @notice Global rolling root across all capabilities and all adapters.
    bytes32 private _globalRoot;

    /// @notice Global receipt count.
    uint256 private _globalCount;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted on every receipt. Consumed by off-chain Circuit 1 witness generation.
    /// @param capabilityHash  Capability the receipt belongs to.
    /// @param index           Zero-based position of this receipt in the capability's chain.
    /// @param receiptHash     keccak256(nullifier, positionIn, positionOut) from the kernel.
    /// @param nullifier       keccak256(intent.nonce, positionCommitment).
    /// @param adapter         Adapter used in the execution.
    /// @param amountIn        Input position amount.
    /// @param amountOut       Gross output from the adapter.
    /// @param newRoot         Per-capability rolling root after this receipt.
    event ReceiptAccumulated(
        bytes32 indexed capabilityHash,
        uint256 indexed index,
        bytes32 receiptHash,
        bytes32 nullifier,
        address indexed adapter,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 newRoot
    );

    event KernelSet(address indexed kernel);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error OnlyKernel();
    error ZeroAddress();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _owner) Ownable(_owner) {}

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    function setKernel(address _kernel) external onlyOwner {
        if (_kernel == address(0)) revert ZeroAddress();
        kernel = _kernel;
        emit KernelSet(_kernel);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IReceiptAccumulator: accumulate
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Append a receipt to the rolling hash chain. Called by CapabilityKernel only.
    function accumulate(
        bytes32 capabilityHash,
        bytes32 receiptHash,
        bytes32 nullifier,
        address adapter,
        uint256 amountIn,
        uint256 amountOut
    ) external override {
        if (msg.sender != kernel) revert OnlyKernel();

        uint256 idx = _receiptCount[capabilityHash];

        // Per-capability rolling root: H(prevRoot, index, receiptHash, nullifier, adapter).
        //
        // The adapter is included so Circuit 1 can prove adapter-filtered claims.
        // Without it, a prover could claim "N ClawloanRepay receipts" for a root that
        // actually commits to a mix of adapters — the circuit has no way to distinguish.
        //
        // abi.encode pads each value to 32 bytes (address zero-pads to 32 bytes):
        //   [32] prevRoot | [32] idx | [32] receiptHash | [32] nullifier | [32] adapter
        //   = 160 bytes total, consistent with the Noir circuit's keccak256 input.
        bytes32 newRoot = keccak256(abi.encode(
            _rollingRoot[capabilityHash],
            idx,
            receiptHash,
            nullifier,
            adapter
        ));

        _rollingRoot[capabilityHash]   = newRoot;
        _receiptCount[capabilityHash]  = idx + 1;
        _adapterCount[capabilityHash][adapter]++;
        _receiptHashes[capabilityHash].push(receiptHash);
        _nullifiers[capabilityHash].push(nullifier);
        _historicalRoots[capabilityHash].push(newRoot); // root after receipt[idx]

        // ── H-3: update per-adapter rolling root ─────────────────────────────
        // Compute a separate hash chain that only includes receipts through `adapter`.
        // The formula is identical to the global chain but the index is the adapter-specific
        // receipt count (before increment) so Circuit 1 can reuse the same rolling-root logic.
        uint256 adapterIdx = _adapterCount[capabilityHash][adapter] - 1; // already incremented above
        bytes32 adapterNewRoot = keccak256(abi.encode(
            _adapterRollingRoot[capabilityHash][adapter],
            adapterIdx,
            receiptHash,
            nullifier,
            adapter
        ));
        _adapterRollingRoot[capabilityHash][adapter] = adapterNewRoot;
        _adapterHistoricalRoots[capabilityHash][adapter].push(adapterNewRoot);
        _adapterReceiptHashes[capabilityHash][adapter].push(receiptHash);
        _adapterNullifiers[capabilityHash][adapter].push(nullifier);

        // Global rolling root — chains all receipts across all capabilities.
        _globalRoot = keccak256(abi.encode(_globalRoot, _globalCount, receiptHash));
        _globalCount++;

        emit ReceiptAccumulated(
            capabilityHash,
            idx,
            receiptHash,
            nullifier,
            adapter,
            amountIn,
            amountOut,
            newRoot
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IReceiptAccumulator: view
    // ─────────────────────────────────────────────────────────────────────────

    function rollingRoot(bytes32 capabilityHash)
        external view override returns (bytes32)
    {
        return _rollingRoot[capabilityHash];
    }

    /// @notice Returns the rolling root after exactly `index` receipts.
    ///         index == 0 → bytes32(0)  (initial root before any receipts).
    ///         index == receiptCount → current rollingRoot.
    ///         Reverts if index > receiptCount.
    function rootAtIndex(bytes32 capabilityHash, uint256 index)
        external view override returns (bytes32)
    {
        if (index == 0) return bytes32(0);
        bytes32[] storage roots = _historicalRoots[capabilityHash];
        require(index <= roots.length, "ReceiptAccumulator: index out of range");
        return roots[index - 1];
    }

    function receiptCount(bytes32 capabilityHash)
        external view override returns (uint256)
    {
        return _receiptCount[capabilityHash];
    }

    function adapterReceiptCount(bytes32 capabilityHash, address adapter)
        external view override returns (uint256)
    {
        return _adapterCount[capabilityHash][adapter];
    }

    function getReceiptHashes(bytes32 capabilityHash)
        external view override returns (bytes32[] memory)
    {
        return _receiptHashes[capabilityHash];
    }

    function getNullifiers(bytes32 capabilityHash)
        external view override returns (bytes32[] memory)
    {
        return _nullifiers[capabilityHash];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // H-3: Per-adapter view functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the per-adapter rolling root after exactly `index` adapter receipts.
    ///
    ///   index == 0                                  → bytes32(0)
    ///   index == adapterReceiptCount(cap, adapter)  → current adapter root
    ///
    /// Use as Circuit 1 `accumulator_root` when adapterFilter is set. The circuit proves
    /// the first N adapter-specific receipts hash to this root.  Because the root is built
    /// only from receipts through `adapter`, interleaved receipts from other adapters do not
    /// affect it — fixing the adapter-interleaving proof failure described in audit finding H-3.
    function adapterRootAtIndex(bytes32 capabilityHash, address adapter, uint256 index)
        external view override returns (bytes32)
    {
        if (index == 0) return bytes32(0);
        bytes32[] storage roots = _adapterHistoricalRoots[capabilityHash][adapter];
        require(index <= roots.length, "ReceiptAccumulator: adapter index out of range");
        return roots[index - 1];
    }

    /// @notice Adapter-filtered receipt hashes for off-chain Circuit 1 witness generation.
    function getAdapterReceiptHashes(bytes32 capabilityHash, address adapter)
        external view override returns (bytes32[] memory)
    {
        return _adapterReceiptHashes[capabilityHash][adapter];
    }

    /// @notice Adapter-filtered nullifiers for off-chain Circuit 1 witness generation.
    function getAdapterNullifiers(bytes32 capabilityHash, address adapter)
        external view override returns (bytes32[] memory)
    {
        return _adapterNullifiers[capabilityHash][adapter];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Global view
    // ─────────────────────────────────────────────────────────────────────────

    function globalRoot() external view returns (bytes32) { return _globalRoot; }
    function globalCount() external view returns (uint256) { return _globalCount; }
}
