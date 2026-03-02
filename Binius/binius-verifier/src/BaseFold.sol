// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "./GF128.sol";
import "./Transcript.sol";
import "./MerkleLib.sol";
import "./BiniusCompress.sol";
import "./FRIFold.sol";

/// @title BaseFold -- FRI polynomial commitment verifier for binius64
/// @notice Verifies the BaseFold/FRI polynomial commitment opening.
///
///         The protocol interleaves sumcheck with FRI folding:
///
///         Phase 1: Interleaved sumcheck + FRI fold (17 rounds)
///           - Each round: read 2 GF128 values (sumcheck poly coeffs), sample challenge
///           - At rounds 4, 8, 12: also read a 32-byte Merkle commitment
///           - Total: 17 x 32 + 3 x 32 = 640 bytes
///
///         Phase 2: Terminate codeword (64 GF128 values = 1024 bytes)
///
///         Phase 3: Pre-queried Merkle layers (3 layers)
///           - Layer 0 (trace oracle):   256 digests = 8192 bytes  (6 siblings per query)
///           - Layer 1 (round-4 oracle): 256 digests = 8192 bytes  (2 siblings per query)
///           - Layer 2 (round-8 oracle):  64 digests = 2048 bytes  (0 siblings per query)
///           - Total: 18432 bytes
///
///         Phase 4: Query phase (232 queries x 1024 bytes = 237568 bytes)
///           - Per query: trace opening (448 bytes) + oracle1 opening (320) + oracle2 opening (256)
///
///         Grand total: 640 + 1024 + 18432 + 237568 = 257664 bytes
library BaseFold {
    using GF128 for uint256;
    using Transcript for Transcript.State;

    uint256 internal constant N_FOLD_ROUNDS = 17;
    uint256 internal constant LOG_BATCH_SIZE = 4;
    uint256 internal constant LOG_INV_RATE = 1;
    // N_QUERIES is now a parameter to verify(); this constant is the production default.
    // Callers may reduce this for lower-security / cheaper-gas deployments (min ~30 for 80-bit
    // soundness; 232 = 100-bit security with 2^-80 query-phase error).
    uint256 internal constant N_QUERIES_DEFAULT = 232;
    uint256 internal constant TERMINATE_CW_SIZE = 64;  // 2^(18 - 12) = 2^6
    uint256 internal constant INDEX_BITS = 14;         // trace oracle leaf count = 2^14

    uint256 internal constant LAYER0_SIZE = 256;       // pre-queried nodes for trace oracle
    uint256 internal constant LAYER1_SIZE = 256;       // pre-queried nodes for round-4 oracle
    uint256 internal constant LAYER2_SIZE = 64;        // pre-queried nodes for round-8 oracle

    uint256 internal constant ORACLE0_SIBLINGS = 6;    // 14 - 8 = 6
    uint256 internal constant ORACLE1_SIBLINGS = 2;    // 10 - 8 = 2
    uint256 internal constant ORACLE2_SIBLINGS = 0;    // 6 - 6 = 0

    uint256 internal constant COMMIT_ROUND_0 = 4;
    uint256 internal constant COMMIT_ROUND_1 = 8;
    uint256 internal constant COMMIT_ROUND_2 = 12;

    struct BaseFoldOutput {
        uint256[] challenges;    // 17 fold/sumcheck challenges
        uint256 finalSumcheck;   // final sumcheck evaluation
    }

    /// @notice Verify the BaseFold/FRI polynomial commitment opening.
    /// @param t         Fiat-Shamir transcript.
    /// @param claim     Initial sumcheck claim (from ring-switch).
    /// @param traceRoot Merkle root of the trace oracle (committed before BaseFold).
    /// @param nQueries  Number of FRI queries.  Use N_QUERIES_DEFAULT (232) for 100-bit security.
    ///                  Reduce only on L2 / appchains where gas costs permit trading security for
    ///                  speed; 80 queries ≈ 87-bit security, 50 queries ≈ 80-bit security.
    ///                  MUST match the Rust prover's nFriQueries parameter exactly.
    function verify(
        Transcript.State memory t,
        uint256 claim,
        bytes32 traceRoot,
        uint256 nQueries
    ) internal view returns (BaseFoldOutput memory output) {
        // ── Phase 1: Interleaved sumcheck + FRI fold (640 bytes) ──────────────
        output.challenges = new uint256[](N_FOLD_ROUNDS);
        uint256 currentSum = claim;
        bytes32 commitRound4;
        bytes32 commitRound8;
        bytes32 commitRound12;

        for (uint256 round = 0; round < N_FOLD_ROUNDS; round++) {
            uint256 a0 = t.messageGF128();
            uint256 a1 = t.messageGF128();
            uint256 a2 = currentSum ^ a1;

            if (round == COMMIT_ROUND_0) {
                commitRound4 = t.messageBytes32();
            } else if (round == COMMIT_ROUND_1) {
                commitRound8 = t.messageBytes32();
            } else if (round == COMMIT_ROUND_2) {
                commitRound12 = t.messageBytes32();
            }

            uint256 alpha = t.sampleGF128();
            output.challenges[round] = alpha;

            currentSum = a0 ^ GF128.mul(alpha, a1 ^ GF128.mul(alpha, a2));
        }
        output.finalSumcheck = currentSum;

        // ── Phase 2: Terminate codeword (1024 bytes) ──────────────────────────
        uint256[] memory termCW = new uint256[](TERMINATE_CW_SIZE);
        for (uint256 i = 0; i < TERMINATE_CW_SIZE; i++) {
            termCW[i] = t.decommitGF128();
        }

        // ── Phase 3: Pre-queried Merkle layers (18432 bytes) ──────────────────
        bytes32[] memory layer0 = _readDecommitDigests(t, LAYER0_SIZE);
        bytes32[] memory layer1 = _readDecommitDigests(t, LAYER1_SIZE);
        bytes32[] memory layer2 = _readDecommitDigests(t, LAYER2_SIZE);

        // ── Phase 4: Query phase (nQueries × 1024 bytes) ─────────────────────
        require(nQueries >= 30, "BaseFold: nQueries below 30 is unsound");
        _verifyQueries(
            t,
            output.challenges,
            traceRoot,
            layer0, layer1, layer2,
            termCW,
            nQueries
        );
    }

    function _readDecommitDigests(Transcript.State memory t, uint256 n) private pure returns (bytes32[] memory d) {
        d = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            d[i] = t.decommitBytes32();
        }
    }

    function _verifyQueries(
        Transcript.State memory t,
        uint256[] memory challenges,
        bytes32 traceRoot,
        bytes32[] memory layer0,
        bytes32[] memory layer1,
        bytes32[] memory layer2,
        uint256[] memory termCW,
        uint256 nQueries
    ) private view {
        for (uint256 q = 0; q < nQueries; q++) {
            uint256 idx0 = _sampleQueryIndex(t);
            uint256 idx1 = idx0 >> LOG_BATCH_SIZE;
            uint256 idx2 = idx1 >> LOG_BATCH_SIZE;

            // ── Trace oracle opening: 16 GF128 + 6 siblings (448 bytes) ──
            uint256[] memory v0 = _readCoset(t);
            bytes32[] memory s0 = _readSiblings(t, ORACLE0_SIBLINGS);

            // ── Oracle 1 opening: 16 GF128 + 2 siblings (320 bytes) ──
            uint256[] memory v1 = _readCoset(t);
            bytes32[] memory s1 = _readSiblings(t, ORACLE1_SIBLINGS);

            // ── Oracle 2 opening: 16 GF128 + 0 siblings (256 bytes) ──
            uint256[] memory v2 = _readCoset(t);

            // ── Merkle proof verification ──
            {
                bytes32 leaf0 = _hashCoset(v0);
                require(
                    _verifyPartialPath(leaf0, s0, idx0, layer0),
                    "BaseFold: trace oracle path failed"
                );
            }

            {
                bytes32 leaf1 = _hashCoset(v1);
                require(
                    _verifyPartialPath(leaf1, s1, idx1, layer1),
                    "BaseFold: oracle1 path failed"
                );
            }

            {
                bytes32 leaf2 = _hashCoset(v2);
                require(idx2 < layer2.length, "BaseFold: idx2 OOB");
                require(leaf2 == layer2[idx2], "BaseFold: oracle2 leaf mismatch");
            }

            // ── FRI fold consistency checks ──

            // Trace fold: interleaved fold using eq_ind tensor (challenges[0..4])
            {
                uint256[] memory interleaveChallenges = new uint256[](4);
                for (uint256 i = 0; i < 4; i++) interleaveChallenges[i] = challenges[i];
                uint256 f01 = FRIFold.foldInterleaved(v0, interleaveChallenges);
                require(f01 == v1[idx0 & 0xf], "BaseFold: fold trace->oracle1 failed");
            }

            // Oracle 1 fold: NTT fold (challenges[4..8], logLen=14)
            {
                uint256[] memory foldCh1 = new uint256[](4);
                for (uint256 i = 0; i < 4; i++) foldCh1[i] = challenges[4 + i];
                uint256 f12 = FRIFold.foldChunk(v1, foldCh1, 14, idx1);
                require(f12 == v2[idx1 & 0xf], "BaseFold: fold oracle1->oracle2 failed");
            }

            // Oracle 2 fold: NTT fold (challenges[8..12], logLen=10)
            {
                uint256[] memory foldCh2 = new uint256[](4);
                for (uint256 i = 0; i < 4; i++) foldCh2[i] = challenges[8 + i];
                uint256 f2t = FRIFold.foldChunk(v2, foldCh2, 10, idx2);
                require(f2t == termCW[idx2], "BaseFold: fold oracle2->terminate failed");
            }
        }
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /// @notice Sample query index (4 bytes LE u32, masked to INDEX_BITS).
    function _sampleQueryIndex(Transcript.State memory t) private view returns (uint256 idx) {
        bytes memory raw = t.sampleBytes(4);
        assembly {
            let b := shr(224, mload(add(raw, 32)))
            // Interpret 4 bytes as little-endian u32
            idx := 0
            idx := or(idx, shl(24, and(b, 0xff)))
            idx := or(idx, shl(16, and(shr(8, b), 0xff)))
            idx := or(idx, shl(8, and(shr(16, b), 0xff)))
            idx := or(idx, and(shr(24, b), 0xff))
        }
        idx = idx & ((1 << INDEX_BITS) - 1);
    }

    /// @notice Read 16 GF128 coset values (256 bytes) — decommitment, NOT observed.
    function _readCoset(Transcript.State memory t) private pure returns (uint256[] memory v) {
        v = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) {
            v[i] = t.decommitGF128();
        }
    }

    /// @notice Read n Merkle siblings — decommitment, NOT observed.
    function _readSiblings(Transcript.State memory t, uint256 n) private pure returns (bytes32[] memory s) {
        s = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            s[i] = t.decommitBytes32();
        }
    }

    /// @notice Hash 16 GF128 coset values to a Merkle leaf (SHA256 of 256 packed LE bytes).
    ///
    /// @dev Assembly-optimized: uses bswap128 to byte-reverse each 128-bit GF128 value
    ///      and packs two values per 32-byte mstore.  This avoids the 256-iteration
    ///      Solidity byte loop and reduces gas from ~50k to ~3k per call.
    ///
    ///      bswap128 algorithm (4 butterfly passes on the low 128 bits of a uint256):
    ///        1. swap adjacent bytes      (mask 0x00FF…)
    ///        2. swap adjacent 2-byte pairs (mask 0x0000FFFF…)
    ///        3. swap adjacent 4-byte groups (mask 0x00000000FFFFFFFF…)
    ///        4. swap 8-byte halves
    function _hashCoset(uint256[] memory vals) private view returns (bytes32 result) {
        assembly {
            // Allocate 256-byte scratch buffer from free pointer.
            let buf    := mload(0x40)
            let bufEnd := add(buf, 256)

            // Write each GF128 element as 16 LE bytes.
            // Two values packed into each 32-byte mstore slot.
            // bswap128(v) reverses the byte order of the low 128 bits so that
            // when mstore writes in big-endian, the bytes land in LE order in memory.
            let vBase := add(vals, 32) // skip length slot
            for { let k := 0 } lt(k, 8) { k := add(k, 1) } {
                // Load pair (v0, v1)
                let v0 := mload(add(vBase, mul(add(mul(k, 2), 0), 32)))
                let v1 := mload(add(vBase, mul(add(mul(k, 2), 1), 32)))

                // bswap128(v0): 4-pass butterfly byte-reversal on low 128 bits
                let r0 := v0
                let m1 := 0x00ff00ff00ff00ff00ff00ff00ff00ff
                r0 := or(shl(8, and(r0, m1)), and(shr(8, r0), m1))
                let m2 := 0x0000ffff0000ffff0000ffff0000ffff
                r0 := or(shl(16, and(r0, m2)), and(shr(16, r0), m2))
                let m3 := 0x00000000ffffffff00000000ffffffff
                r0 := or(shl(32, and(r0, m3)), and(shr(32, r0), m3))
                r0 := or(shl(64, and(r0, 0xffffffffffffffff)), shr(64, r0))
                r0 := and(r0, 0xffffffffffffffffffffffffffffffff)

                // bswap128(v1)
                let r1 := v1
                r1 := or(shl(8, and(r1, m1)), and(shr(8, r1), m1))
                r1 := or(shl(16, and(r1, m2)), and(shr(16, r1), m2))
                r1 := or(shl(32, and(r1, m3)), and(shr(32, r1), m3))
                r1 := or(shl(64, and(r1, 0xffffffffffffffff)), shr(64, r1))
                r1 := and(r1, 0xffffffffffffffffffffffffffffffff)

                // Pack: high 128 bits = bswap128(v0), low 128 bits = bswap128(v1)
                // mstore writes high bits first, so buf[k*32..k*32+15] = LE(v0),
                //                                    buf[k*32+16..k*32+31] = LE(v1)
                mstore(add(buf, mul(k, 32)), or(shl(128, r0), r1))
            }

            // SHA256 of the 256-byte packed buffer
            let ok := staticcall(gas(), 0x02, buf, 256, 0x00, 32)
            if iszero(ok) { revert(0, 0) }
            result := mload(0x00)
        }
    }

    /// @notice Verify a partial Merkle path from leaf up to a pre-queried layer node.
    function _verifyPartialPath(
        bytes32 leaf,
        bytes32[] memory siblings,
        uint256 leafIdx,
        bytes32[] memory layer
    ) private pure returns (bool) {
        bytes32 current = leaf;
        uint256 idx = leafIdx;
        for (uint256 i = 0; i < siblings.length; i++) {
            if (idx & 1 == 0) {
                current = _compressPair(current, siblings[i]);
            } else {
                current = _compressPair(siblings[i], current);
            }
            idx >>= 1;
        }
        if (idx >= layer.length) return false;
        return current == layer[idx];
    }

    /// @notice Binius Merkle node: SHA256 compression with domain-separated IV.
    function _compressPair(bytes32 left, bytes32 right) private pure returns (bytes32) {
        return BiniusCompress.compress(left, right);
    }
}
