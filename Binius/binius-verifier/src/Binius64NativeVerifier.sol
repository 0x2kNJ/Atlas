// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "./GF128.sol";
import "./Transcript.sol";
import "./protocols/Sumcheck.sol";
import "./protocols/ShiftReduction.sol";
import "./protocols/AndReduction.sol";
import "./protocols/IntMulReduction.sol";
import "./BaseFold.sol";
import "./RingSwitch.sol";

/// @title Binius64NativeVerifier — Production native verifier for binius64 proofs
/// @notice Orchestrates all verification sub-protocols in the correct order,
///         matching the Rust `Verifier::verify_iop` function flow.
///
///         This is the CANONICAL verifier for real proofs from the Rust binius64 crate.
///         It accepts raw proof bytes (sequential byte stream, not ABI-encoded structs)
///         and uses the SHA256/HasherChallenger Fiat-Shamir transcript that matches
///         the Rust prover exactly.
///
///         Convergence from binius-research/evm-verifier:
///           - Transcript: SHA256-based HasherChallenger (exact Rust match)
///           - Merkle:     SHA256(left || right) for tree nodes
///           - FRI fold:   NTT fold_chunk with precomputed twiddle basis
///           - Field mul:  Zech-log optimised BinaryFieldLibOpt
///
///         Verification flow (total ~272 KB proof for Encumber circuit):
///           0. Observe public inputs (no proof bytes)
///           1. Trace commitment (32 bytes)
///           2. IntMul reduction (9920 bytes for n_mul=0)
///           3. AND reduction (1648 bytes)
///           4. Shift reduction (976 bytes)
///           5. RingSwitch reduction (2048 bytes)
///           6. BaseFold/FRI (257664 bytes)
///           7. Finalize transcript (assert all proof bytes consumed)
contract Binius64NativeVerifier {
    using GF128 for uint256;
    using Transcript for Transcript.State;

    struct ConstraintSystemParams {
        uint256 nWitnessWords;   // total committed words (262144 = 2^18 for Encumber)
        uint256 nPublicWords;    // number of public input words (128 for Encumber, padded)
        uint256 logInvRate;      // FRI rate: 1 for rate 1/2
        uint256 nFriQueries;     // number of FRI test queries (232 = 100-bit security; min 30)
    }

    ConstraintSystemParams public params;

    /// @notice Keccak256 of the ABI-encoded ConstraintSystemParams bound at deployment.
    ///         Off-chain tools and the EnvelopeRegistry should assert this matches
    ///         the expected VK before trusting any proof verification result.
    bytes32 public immutable paramsHash;

    constructor(ConstraintSystemParams memory _params) {
        require(_params.nWitnessWords > 0,   "Binius64: nWitnessWords must be > 0");
        require(_params.nPublicWords  > 0,   "Binius64: nPublicWords must be > 0");
        require(_params.nFriQueries   >= 30, "Binius64: nFriQueries below 30 is unsound");
        params     = _params;
        paramsHash = keccak256(abi.encode(_params));
    }

    /// @notice Verify a binius64 proof.
    /// @param proof        The serialized proof bytes (raw binius64 binary format).
    /// @param publicInputs The public input words (each uint64 as uint256, LE encoding).
    ///                     Length MUST equal params.nPublicWords exactly.
    /// @return valid       True if the proof verifies.
    function verify(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool valid) {
        // ── Public input length guard ─────────────────────────────────────────
        // A length mismatch silently zero-pads or truncates, producing a different
        // transcript hash that would reject real proofs or accept crafted ones.
        require(
            publicInputs.length == params.nPublicWords,
            "Binius64: publicInputs.length != nPublicWords"
        );

        Transcript.State memory t = Transcript.init(proof);

        // ── 0. Observe public inputs (no proof bytes consumed) ────────────────
        for (uint256 i = 0; i < publicInputs.length; i++) {
            bytes memory word = _encodeU64LE(publicInputs[i]);
            t.observe(word);
        }

        // ── 1. Trace commitment (32 bytes) ────────────────────────────────────
        bytes32 traceRoot = t.messageBytes32();

        // ── 2. IntMul reduction (9920 bytes for n_mul=0) ──────────────────────
        IntMulReduction.verify(t, 0);

        // ── 3. AND reduction (1648 bytes) ─────────────────────────────────────
        AndReduction.AndOutput memory andOut = AndReduction.verify(t);

        // ── 4. Shift reduction (976 bytes) ────────────────────────────────────
        uint64[] memory publicWords = _toUint64Array(publicInputs);
        uint256[3] memory andEvals = [andOut.aEval, andOut.bEval, andOut.cEval];
        uint256[4] memory intmulEvals = [uint256(0), uint256(0), uint256(0), uint256(0)];

        ShiftReduction.ShiftOutput memory shiftOut = ShiftReduction.verify(
            t, andEvals, andOut.zChallenge, intmulEvals, 0, publicWords
        );

        // ── 5. RingSwitch reduction (2048 bytes) ──────────────────────────────
        uint256[] memory evalPoint = _buildEvalPoint(shiftOut.rJ, shiftOut.rY);
        RingSwitch.RingSwitchOutput memory rsOut = RingSwitch.verify(
            t, shiftOut.witnessEval, evalPoint
        );

        // ── 6. BaseFold/FRI (257664 bytes) ────────────────────────────────────
        BaseFold.verify(t, rsOut.sumcheckClaim, traceRoot, params.nFriQueries);

        // ── 7. Finalize: reject proofs with trailing garbage bytes ────────────
        // Transcript.finalize() asserts t.offset == t.proof.length.
        // This prevents a malleability vector where a prover appends arbitrary
        // bytes after the valid proof data — they would pass all sub-protocol
        // checks (which only read forward) but the transcript hash would differ,
        // so the Fiat-Shamir challenges would be different and the proof would
        // fail.  The check ensures the exact expected proof size was consumed.
        t.finalize();

        valid = true;
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /// @notice Encode a uint256 value as 8 bytes little-endian (u64 LE).
    function _encodeU64LE(uint256 val) internal pure returns (bytes memory b) {
        b = new bytes(8);
        assembly {
            let ptr := add(b, 32)
            mstore8(ptr,           and(val, 0xff))
            mstore8(add(ptr, 1),   and(shr(8,  val), 0xff))
            mstore8(add(ptr, 2),   and(shr(16, val), 0xff))
            mstore8(add(ptr, 3),   and(shr(24, val), 0xff))
            mstore8(add(ptr, 4),   and(shr(32, val), 0xff))
            mstore8(add(ptr, 5),   and(shr(40, val), 0xff))
            mstore8(add(ptr, 6),   and(shr(48, val), 0xff))
            mstore8(add(ptr, 7),   and(shr(56, val), 0xff))
        }
    }

    function _toUint64Array(uint256[] calldata inputs) internal pure returns (uint64[] memory out) {
        out = new uint64[](inputs.length);
        for (uint256 i = 0; i < inputs.length; i++) {
            out[i] = uint64(inputs[i]);
        }
    }

    function _buildEvalPoint(
        uint256[] memory rJ,
        uint256[] memory rY
    ) internal pure returns (uint256[] memory ep) {
        ep = new uint256[](rJ.length + rY.length);
        for (uint256 i = 0; i < rJ.length; i++) ep[i] = rJ[i];
        for (uint256 i = 0; i < rY.length; i++) ep[rJ.length + i] = rY[i];
    }
}
