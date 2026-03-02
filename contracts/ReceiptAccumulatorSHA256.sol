// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IReceiptAccumulator} from "./interfaces/IReceiptAccumulator.sol";

/// @title ReceiptAccumulatorSHA256
/// @notice Drop-in replacement for ReceiptAccumulator that uses SHA-256 instead of keccak256
///         for the rolling root hash chain.
///
/// ─── Why SHA-256 instead of keccak256 ────────────────────────────────────────
///
/// The production ReceiptAccumulator uses keccak256 (cheap on EVM, native in Noir).
/// The Binius prover in binius-research/envelope-circuits/src/compliance.rs uses
/// DoubleSHA256 (SHA256²) — the same primitive optimised in the binius-circuits
/// bitcoin gadget. Binius's binary-field architecture runs SHA256 ~4× faster than
/// keccak256 in circuit.
///
/// To connect the Binius compliance circuit to on-chain enforcement, the rolling root
/// must be computed the same way on-chain and in-circuit. This contract mirrors the
/// ReceiptAccumulator interface exactly but replaces:
///
///   keccak256(abi.encode(...))  →  sha256(abi.encodePacked(...))
///
/// The public verification path (ComplianceBiniusVerifier, coming in Phase 2) will
/// reference this contract's rollingRoot() instead of ReceiptAccumulator's.
///
/// ─── Rolling root formula ────────────────────────────────────────────────────
///
///   root_0 = capabilityHash   (matches the Binius64 compliance circuit)
///   root_i = sha256(prev_root ‖ index_le32 ‖ receiptHash ‖ nullifier ‖ adapter_padded)
///            [32B] prev  | [8B] index (uint64 LE) | [24B zero] | [32B] receipt | [32B] nf | [32B] adapter
///            = 160 bytes total — matches build_rolling_msg() in compliance.rs exactly.
///
/// Note: index is encoded as uint64 LE in bytes [32..40] with [40..64] zeroed.
/// This matches compliance.rs: `msg[32..40].copy_from_slice(&index.to_le_bytes())`.
///
/// ─── Interface compatibility ─────────────────────────────────────────────────
///
/// Implements IReceiptAccumulator identically to ReceiptAccumulator.
/// The CreditVerifier can be pointed at either accumulator; the Binius verifier
/// (ComplianceBiniusVerifier) must be paired with this contract.

contract ReceiptAccumulatorSHA256 is Ownable2Step, IReceiptAccumulator {

    // ─────────────────────────────────────────────────────────────────────────
    // State (identical layout to ReceiptAccumulator)
    // ─────────────────────────────────────────────────────────────────────────

    address public kernel;

    mapping(bytes32 capabilityHash => bytes32 root) private _rollingRoot;
    mapping(bytes32 capabilityHash => uint256 count) private _receiptCount;
    mapping(bytes32 capabilityHash => mapping(address adapter => uint256)) private _adapterCount;
    mapping(bytes32 capabilityHash => bytes32[] hashes) private _receiptHashes;
    mapping(bytes32 capabilityHash => bytes32[] nulls) private _nullifiers;
    mapping(bytes32 capabilityHash => bytes32[] roots) private _historicalRoots;

    // Per-adapter rolling roots (H-3 fix — same as ReceiptAccumulator)
    mapping(bytes32 capabilityHash => mapping(address adapter => bytes32)) private _adapterRollingRoot;
    mapping(bytes32 capabilityHash => mapping(address adapter => bytes32[])) private _adapterHistoricalRoots;
    mapping(bytes32 capabilityHash => mapping(address adapter => bytes32[])) private _adapterReceiptHashes;
    mapping(bytes32 capabilityHash => mapping(address adapter => bytes32[])) private _adapterNullifiers;

    bytes32 private _globalRoot;
    uint256 private _globalCount;

    // ─────────────────────────────────────────────────────────────────────────
    // Events (identical to ReceiptAccumulator)
    // ─────────────────────────────────────────────────────────────────────────

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
    // Internal: SHA-256 rolling root step
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Compute one step of the rolling root chain using SHA-256.
    ///
    /// Message layout (160 bytes):
    ///   bytes  0– 31: prevRoot
    ///   bytes 32– 39: index as uint64 little-endian
    ///   bytes 40– 63: zero padding (24 bytes)
    ///   bytes 64– 95: receiptHash
    ///   bytes 96–127: nullifier
    ///   bytes128–159: adapter (address, zero-padded to 32 bytes)
    ///
    /// This matches compliance.rs build_rolling_msg() exactly.
    function _sha256RollingStep(
        bytes32 prevRoot,
        uint256 index,
        bytes32 receiptHash,
        bytes32 nullifier,
        address adapter
    ) internal pure returns (bytes32) {
        // Build the 160-byte message manually to match the Rust layout.
        // Bytes 32–39: index as uint64 LE. We use a uint64 cast since indices
        // never exceed 2^64 in practice. The cast truncates — safe for MAX_N=64.
        uint64 idx64 = uint64(index);

        // Pack the 160-byte message.
        // abi.encodePacked uses big-endian for integer types by default.
        // For the index field we need little-endian. We flip it manually.
        bytes memory data = abi.encodePacked(
            prevRoot,                 // 32 bytes — big-endian, same as LE for raw bytes
            _uint64ToLE(idx64),       //  8 bytes — little-endian uint64
            bytes24(0),               // 24 bytes — zero padding
            receiptHash,              // 32 bytes
            nullifier,                // 32 bytes
            bytes12(0),               // 12 bytes — zero-pad address to 32 bytes
            adapter                   // 20 bytes
        );
        // Total: 32 + 8 + 24 + 32 + 32 + 12 + 20 = 160 bytes ✓

        return sha256(data);
    }

    /// @dev Convert a uint64 to its 8-byte little-endian representation.
    function _uint64ToLE(uint64 v) internal pure returns (bytes8) {
        return bytes8(
            (uint64(v & 0xFF) << 56) |
            (uint64((v >>  8) & 0xFF) << 48) |
            (uint64((v >> 16) & 0xFF) << 40) |
            (uint64((v >> 24) & 0xFF) << 32) |
            (uint64((v >> 32) & 0xFF) << 24) |
            (uint64((v >> 40) & 0xFF) << 16) |
            (uint64((v >> 48) & 0xFF) << 8) |
            (uint64((v >> 56) & 0xFF))
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IReceiptAccumulator: accumulate
    // ─────────────────────────────────────────────────────────────────────────

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

        // root_0 = capabilityHash (matches Binius64 compliance circuit).
        // On first accumulation the mapping default is bytes32(0); substitute capabilityHash.
        bytes32 prevRoot = idx == 0 ? capabilityHash : _rollingRoot[capabilityHash];

        bytes32 newRoot = _sha256RollingStep(
            prevRoot,
            idx,
            receiptHash,
            nullifier,
            adapter
        );

        _rollingRoot[capabilityHash]  = newRoot;
        _receiptCount[capabilityHash] = idx + 1;
        _adapterCount[capabilityHash][adapter]++;
        _receiptHashes[capabilityHash].push(receiptHash);
        _nullifiers[capabilityHash].push(nullifier);
        _historicalRoots[capabilityHash].push(newRoot);

        // H-3: per-adapter rolling root (also starts from capabilityHash)
        uint256 adapterIdx = _adapterCount[capabilityHash][adapter] - 1;
        bytes32 adapterPrev = adapterIdx == 0
            ? capabilityHash
            : _adapterRollingRoot[capabilityHash][adapter];
        bytes32 adapterNewRoot = _sha256RollingStep(
            adapterPrev,
            adapterIdx,
            receiptHash,
            nullifier,
            adapter
        );
        _adapterRollingRoot[capabilityHash][adapter] = adapterNewRoot;
        _adapterHistoricalRoots[capabilityHash][adapter].push(adapterNewRoot);
        _adapterReceiptHashes[capabilityHash][adapter].push(receiptHash);
        _adapterNullifiers[capabilityHash][adapter].push(nullifier);

        // Global root (still SHA-256)
        _globalRoot = sha256(abi.encodePacked(_globalRoot, uint256(_globalCount), receiptHash));
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
    // IReceiptAccumulator: view (identical to ReceiptAccumulator)
    // ─────────────────────────────────────────────────────────────────────────

    function rollingRoot(bytes32 capabilityHash)
        external view override returns (bytes32)
    {
        return _rollingRoot[capabilityHash];
    }

    function rootAtIndex(bytes32 capabilityHash, uint256 index)
        external view override returns (bytes32)
    {
        if (index == 0) return capabilityHash;
        bytes32[] storage roots = _historicalRoots[capabilityHash];
        require(index <= roots.length, "ReceiptAccumulatorSHA256: index out of range");
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

    // H-3 per-adapter views
    function adapterRootAtIndex(bytes32 capabilityHash, address adapter, uint256 index)
        external view override returns (bytes32)
    {
        if (index == 0) return capabilityHash;
        bytes32[] storage roots = _adapterHistoricalRoots[capabilityHash][adapter];
        require(index <= roots.length, "ReceiptAccumulatorSHA256: adapter index out of range");
        return roots[index - 1];
    }

    function getAdapterReceiptHashes(bytes32 capabilityHash, address adapter)
        external view override returns (bytes32[] memory)
    {
        return _adapterReceiptHashes[capabilityHash][adapter];
    }

    function getAdapterNullifiers(bytes32 capabilityHash, address adapter)
        external view override returns (bytes32[] memory)
    {
        return _adapterNullifiers[capabilityHash][adapter];
    }

    // Global view
    function globalRoot() external view returns (bytes32) { return _globalRoot; }
    function globalCount() external view returns (uint256) { return _globalCount; }
}
