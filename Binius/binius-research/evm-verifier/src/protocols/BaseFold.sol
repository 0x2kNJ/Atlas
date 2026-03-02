// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "../lib/GF128.sol";
import "../lib/Transcript.sol";
import "../lib/MerkleLib.sol";
import "../lib/BiniusCompress.sol";
import "../lib/FRIFold.sol";

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
    uint256 internal constant N_QUERIES = 232;
    uint256 internal constant TERMINATE_CW_SIZE = 64;  // 2^(18 - 12) = 2^6
    uint256 internal constant INDEX_BITS = 14;         // trace oracle leaf count = 2^14

    uint256 internal constant LAYER0_SIZE = 256;       // pre-queried nodes for trace oracle
    uint256 internal constant LAYER1_SIZE = 256;       // pre-queried nodes for round-4 oracle
    uint256 internal constant LAYER2_SIZE = 64;        // pre-queried nodes for round-8 oracle

    uint256 internal constant ORACLE0_SIBLINGS = 6;    // 14 - 8 = 6
    uint256 internal constant ORACLE1_SIBLINGS = 2;    // 10 - 8 = 2
    uint256 internal constant ORACLE2_SIBLINGS = 0;    // 6 - 6 = 0

    // Round indices at which FRI oracle commitments appear
    uint256 internal constant COMMIT_ROUND_0 = 4;
    uint256 internal constant COMMIT_ROUND_1 = 8;
    uint256 internal constant COMMIT_ROUND_2 = 12;

    struct BaseFoldOutput {
        uint256[] challenges;    // 17 fold/sumcheck challenges
        uint256 finalSumcheck;   // final sumcheck evaluation
    }

    /// @notice Verify the BaseFold/FRI polynomial commitment opening.
    /// @param t          Fiat-Shamir transcript.
    /// @param claim      Initial sumcheck claim (from ring-switch).
    /// @param traceRoot  Merkle root of the trace oracle (committed before BaseFold).
    function verify(
        Transcript.State memory t,
        uint256 claim,
        bytes32 traceRoot
    ) internal view returns (BaseFoldOutput memory output) {
        // ----------------------------------------------------------------
        // Phase 1: Interleaved sumcheck + FRI fold (640 bytes)
        // ----------------------------------------------------------------
        output.challenges = new uint256[](N_FOLD_ROUNDS);
        uint256 currentSum = claim;
        bytes32 commitRound4;
        bytes32 commitRound8;
        bytes32 commitRound12;

        for (uint256 round = 0; round < N_FOLD_ROUNDS; round++) {
            // Read 2 GF128 sumcheck polynomial coefficients (32 bytes)
            uint256 a0 = t.messageGF128();
            uint256 a1 = t.messageGF128();

            // Recover highest coefficient: a2 = currentSum XOR a1
            uint256 a2 = currentSum ^ a1;

            // Read oracle commitment if this is a commit round
            if (round == COMMIT_ROUND_0) {
                commitRound4 = t.messageBytes32();
            } else if (round == COMMIT_ROUND_1) {
                commitRound8 = t.messageBytes32();
            } else if (round == COMMIT_ROUND_2) {
                commitRound12 = t.messageBytes32();
            }

            // Sample fold/sumcheck challenge
            uint256 alpha = t.sampleGF128();
            output.challenges[round] = alpha;

            // Evaluate sumcheck polynomial at alpha via Horner
            currentSum = a0 ^ GF128.mul(alpha, a1 ^ GF128.mul(alpha, a2));
        }
        output.finalSumcheck = currentSum;

        // ----------------------------------------------------------------
        // Phase 2: Terminate codeword (1024 bytes) -- decommitment (NOT observed)
        // ----------------------------------------------------------------
        uint256[] memory termCW = new uint256[](TERMINATE_CW_SIZE);
        for (uint256 i = 0; i < TERMINATE_CW_SIZE; i++) {
            termCW[i] = t.decommitGF128();
        }

        // ----------------------------------------------------------------
        // Phase 3: Pre-queried Merkle layers (18432 bytes) -- decommitment (NOT observed)
        // ----------------------------------------------------------------
        bytes32[] memory layer0 = _readDecommitDigests(t, LAYER0_SIZE);
        bytes32[] memory layer1 = _readDecommitDigests(t, LAYER1_SIZE);
        bytes32[] memory layer2 = _readDecommitDigests(t, LAYER2_SIZE);

        // ----------------------------------------------------------------
        // Phase 4: Query phase (237568 bytes)
        // ----------------------------------------------------------------
        _verifyQueries(
            t,
            output.challenges,
            traceRoot,
            layer0, layer1, layer2,
            termCW
        );
    }

    /// @notice Read n SHA256 digests from the proof tape (decommitment, NOT observed).
    function _readDecommitDigests(Transcript.State memory t, uint256 n) private pure returns (bytes32[] memory d) {
        d = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            d[i] = t.decommitBytes32();
        }
    }

    /// @notice Verify all 232 FRI queries.
    function _verifyQueries(
        Transcript.State memory t,
        uint256[] memory challenges,
        bytes32 traceRoot,
        bytes32[] memory layer0,
        bytes32[] memory layer1,
        bytes32[] memory layer2,
        uint256[] memory termCW
    ) private view {
        for (uint256 q = 0; q < N_QUERIES; q++) {
            uint256 idx0 = _sampleQueryIndex(t);
            uint256 idx1 = idx0 >> LOG_BATCH_SIZE;
            uint256 idx2 = idx1 >> LOG_BATCH_SIZE;

            // ---- Trace oracle opening: 16 GF128 + 6 siblings (448 bytes) ----
            uint256[] memory v0 = _readCoset(t);
            bytes32[] memory s0 = _readSiblings(t, ORACLE0_SIBLINGS);

            // ---- Oracle 1 opening: 16 GF128 + 2 siblings (320 bytes) ----
            uint256[] memory v1 = _readCoset(t);
            bytes32[] memory s1 = _readSiblings(t, ORACLE1_SIBLINGS);

            // ---- Oracle 2 opening: 16 GF128 + 0 siblings (256 bytes) ----
            uint256[] memory v2 = _readCoset(t);

            // ---- Merkle proof verification ----
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

            // ---- FRI fold consistency checks ----
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
            // rs_code.log_len()=14, fold_round=4 → log_n=10
            {
                uint256[] memory foldCh2 = new uint256[](4);
                for (uint256 i = 0; i < 4; i++) foldCh2[i] = challenges[8 + i];
                uint256 f2t = FRIFold.foldChunk(v2, foldCh2, 10, idx2);
                require(f2t == termCW[idx2], "BaseFold: fold oracle2->terminate failed");
            }
        }
    }

    // ---- Internal helpers -----------------------------------------------

    /// @notice Sample query index from the transcript (4 bytes LE u32, masked to INDEX_BITS).
    ///         Matches Rust's sample_bits_reader which reads size_of::<u32>() = 4 bytes.
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

    /// @notice Read 16 GF128 coset values (256 bytes) -- decommitment (NOT observed).
    function _readCoset(Transcript.State memory t) private pure returns (uint256[] memory v) {
        v = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) {
            v[i] = t.decommitGF128();
        }
    }

    /// @notice Read n Merkle siblings (n x 32 bytes) -- decommitment (NOT observed).
    function _readSiblings(Transcript.State memory t, uint256 n) private pure returns (bytes32[] memory s) {
        s = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            s[i] = t.decommitBytes32();
        }
    }

    /// @notice Hash 16 GF128 coset values to a Merkle leaf (SHA256 of 256 packed LE bytes).
    function _hashCoset(uint256[] memory vals) private view returns (bytes32 result) {
        bytes memory packed = new bytes(256);
        for (uint256 i = 0; i < 16; i++) {
            uint256 v = vals[i];
            for (uint256 b = 0; b < 16; b++) {
                packed[i * 16 + b] = bytes1(uint8(v >> (b * 8)));
            }
        }
        assembly {
            let ok := staticcall(gas(), 0x02, add(packed, 32), 256, 0x00, 32)
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
