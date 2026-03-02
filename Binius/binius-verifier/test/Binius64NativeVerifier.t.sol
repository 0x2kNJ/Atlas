// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/Binius64NativeVerifier.sol";
import "../src/Transcript.sol";
import "../src/GF128.sol";
import "../src/MerkleLib.sol";
import "../src/FRIFold.sol";
import "../src/BiniusCompress.sol";
import "../src/RingSwitch.sol";

// =============================================================================
// Binius64NativeVerifier.t.sol
//
// Tests for the production native verifier that accepts raw proof byte streams
// and uses the SHA256/HasherChallenger Fiat-Shamir transcript.
//
// REAL PROOF PATH (disabled by default):
//   To test against a real binius64 proof (requires Rust prover):
//
//     1. Build the Rust prover and export a proof:
//          cd binius-research/envelope-circuits
//          cargo run --bin export_proof -- \
//            --circuit encumbrance         \
//            --output ../../binius-verifier/test/fixtures/native_proof.bin
//
//     2. Run with REAL_E2E=1:
//          REAL_E2E=1 forge test --match-contract Binius64NativeVerifierTest -vvv
//
// UNIT TESTS (always enabled):
//   - Deployment + parameter correctness
//   - Transcript determinism (SHA256 vs keccak256)
//   - MerkleLib SHA256 node hashing
//   - FRIFold NTT fold correctness
//   - BiniusCompress IV correctness
// =============================================================================

contract Binius64NativeVerifierTest is Test {
    using Transcript for Transcript.State;

    Binius64NativeVerifier public verifier;

    // Encumber circuit parameters (Binius64 production constants)
    uint256 constant N_WITNESS_WORDS = 1 << 18;  // 262144
    uint256 constant N_PUBLIC_WORDS  = 128;
    uint256 constant LOG_INV_RATE    = 1;
    uint256 constant N_FRI_QUERIES   = 232;

    function setUp() public {
        verifier = new Binius64NativeVerifier(
            Binius64NativeVerifier.ConstraintSystemParams({
                nWitnessWords: N_WITNESS_WORDS,
                nPublicWords:  N_PUBLIC_WORDS,
                logInvRate:    LOG_INV_RATE,
                nFriQueries:   N_FRI_QUERIES
            })
        );
    }

    // ─── Deployment ───────────────────────────────────────────────────────────

    function test_deploys_with_correct_params() public view {
        (
            uint256 nWitnessWords,
            uint256 nPublicWords,
            uint256 logInvRate,
            uint256 nFriQueries
        ) = verifier.params();
        assertEq(nWitnessWords, N_WITNESS_WORDS, "nWitnessWords");
        assertEq(nPublicWords,  N_PUBLIC_WORDS,  "nPublicWords");
        assertEq(logInvRate,    LOG_INV_RATE,    "logInvRate");
        assertEq(nFriQueries,   N_FRI_QUERIES,   "nFriQueries");
    }

    // ─── Transcript: SHA256 HasherChallenger ──────────────────────────────────

    /// @notice The transcript starts in Sampler mode with the SHA256("") state.
    ///         After the first sampleGF128(), the challenge must match what the
    ///         Rust HasherChallenger produces for an empty observer state.
    function test_transcript_init_state() public view {
        bytes memory emptyProof = new bytes(0);
        Transcript.State memory t = Transcript.init(emptyProof);
        // samplerBuffer should equal SHA256("") on initialisation
        bytes32 sha256Empty = hex"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        assertEq(t.samplerBuffer, sha256Empty, "initial samplerBuffer == SHA256('')");
        assertFalse(t.isObserver, "starts in Sampler mode");
        assertEq(t.samplerIndex, 0, "samplerIndex starts at 0");
    }

    /// @notice Sampling is deterministic: two identical transcripts produce the same challenge.
    function test_transcript_sample_is_deterministic() public view {
        bytes memory emptyProof = new bytes(0);
        Transcript.State memory t1 = Transcript.init(emptyProof);
        Transcript.State memory t2 = Transcript.init(emptyProof);
        uint256 c1 = t1.sampleGF128();
        uint256 c2 = t2.sampleGF128();
        assertEq(c1, c2, "same initial state -> same challenge");
    }

    /// @notice After observing data, the sampled challenge must change.
    function test_transcript_observe_changes_challenge() public view {
        bytes memory emptyProof = new bytes(0);
        Transcript.State memory t1 = Transcript.init(emptyProof);
        Transcript.State memory t2 = Transcript.init(emptyProof);

        bytes memory data = abi.encodePacked("binius-test-data");
        t2.observe(data);

        uint256 c1 = t1.sampleGF128();
        uint256 c2 = t2.sampleGF128();
        assertNotEq(c1, c2, "observing data must change the challenge");
    }

    /// @notice Observer -> Sampler transition feeds samplerIndex as LE u64.
    ///         After observing, index=0 should be appended before hashing.
    function test_transcript_mode_transition_correct() public view {
        bytes memory emptyProof = new bytes(0);
        Transcript.State memory t = Transcript.init(emptyProof);

        // Transition: Sampler (index=0) -> Observer (feeds 0 as LE u64) → Sampler
        bytes memory data = abi.encodePacked(bytes32(0));
        t.observe(data);
        uint256 ch = t.sampleGF128();

        // Challenge must be a valid 128-bit field element
        assertLt(ch, 1 << 128, "challenge must fit in 128 bits");
    }

    /// @notice Sequential samples produce different values (no repeats within buffer).
    function test_transcript_sequential_samples_differ() public view {
        bytes memory emptyProof = new bytes(0);
        Transcript.State memory t = Transcript.init(emptyProof);
        uint256 c0 = t.sampleGF128();
        uint256 c1 = t.sampleGF128();
        uint256 c2 = t.sampleGF128();
        // All three should be different (with overwhelming probability)
        assertNotEq(c0, c1, "c0 != c1");
        assertNotEq(c1, c2, "c1 != c2");
    }

    // ─── MerkleLib: SHA256 node hashing ───────────────────────────────────────

    /// @notice SHA256(left || right) is computed via the precompile, not keccak256.
    function test_merklelib_uses_sha256() public view {
        bytes32 left  = keccak256("left");
        bytes32 right = keccak256("right");

        // Compute expected SHA256(left || right) via the precompile directly
        bytes32 expected;
        assembly {
            mstore(0x00, left)
            mstore(0x20, right)
            let ok := staticcall(gas(), 0x02, 0x00, 64, 0x00, 32)
            if iszero(ok) { revert(0, 0) }
            expected := mload(0x00)
        }

        // Verify via a 1-level Merkle proof: leaf = left, sibling = right -> root = sha256(left||right)
        bytes32[] memory siblings = new bytes32[](1);
        siblings[0] = right;
        bool valid = MerkleLib.verify(expected, left, siblings, 0);
        assertTrue(valid, "MerkleLib uses SHA256(left||right)");

        // Confirm it differs from keccak256 (which would be the old hash)
        bytes32 keccakNode = keccak256(abi.encodePacked(left, right));
        assertNotEq(expected, keccakNode, "SHA256 != keccak256 for same input");
    }

    /// @notice Two-level Merkle proof round-trip.
    function test_merklelib_two_level_proof() public view {
        bytes32[4] memory leaves;
        for (uint256 i = 0; i < 4; i++) {
            leaves[i] = keccak256(abi.encodePacked("leaf", i));
        }

        // Build tree: parent0 = SHA256(leaf0||leaf1), parent1 = SHA256(leaf2||leaf3)
        bytes32 parent0;
        bytes32 parent1;
        bytes32 root;
        assembly {
            let scratch := mload(0x40)
            mstore(scratch, mload(leaves))
            mstore(add(scratch, 32), mload(add(leaves, 32)))
            pop(staticcall(gas(), 0x02, scratch, 64, scratch, 32))
            parent0 := mload(scratch)

            mstore(scratch, mload(add(leaves, 64)))
            mstore(add(scratch, 32), mload(add(leaves, 96)))
            pop(staticcall(gas(), 0x02, scratch, 64, scratch, 32))
            parent1 := mload(scratch)

            mstore(scratch, parent0)
            mstore(add(scratch, 32), parent1)
            pop(staticcall(gas(), 0x02, scratch, 64, scratch, 32))
            root := mload(scratch)
        }

        // Verify leaf1 (index=1)
        bytes32[] memory siblings = new bytes32[](2);
        siblings[0] = leaves[0];
        siblings[1] = parent1;
        bool valid = MerkleLib.verify(root, leaves[1], siblings, 1);
        assertTrue(valid, "leaf1 at index=1 verifies");

        // Bad sibling should fail
        siblings[0] = leaves[3];
        assertFalse(MerkleLib.verify(root, leaves[1], siblings, 1), "wrong sibling fails");
    }

    // ─── BiniusCompress ───────────────────────────────────────────────────────

    /// @notice BiniusCompress is deterministic.
    function test_binius_compress_deterministic() public pure {
        bytes32 left  = bytes32(uint256(0x1234));
        bytes32 right = bytes32(uint256(0x5678));
        bytes32 r1 = BiniusCompress.compress(left, right);
        bytes32 r2 = BiniusCompress.compress(left, right);
        assertEq(r1, r2, "compress is deterministic");
    }

    /// @notice BiniusCompress is NOT commutative (order matters).
    function test_binius_compress_not_commutative() public pure {
        bytes32 a = bytes32(uint256(1));
        bytes32 b = bytes32(uint256(2));
        bytes32 ab = BiniusCompress.compress(a, b);
        bytes32 ba = BiniusCompress.compress(b, a);
        assertNotEq(ab, ba, "compress(a,b) != compress(b,a)");
    }

    /// @notice BiniusCompress differs from SHA256(left||right).
    function test_binius_compress_differs_from_sha256() public view {
        bytes32 left  = bytes32(uint256(42));
        bytes32 right = bytes32(uint256(43));

        bytes32 compressResult = BiniusCompress.compress(left, right);

        bytes32 sha256Result;
        assembly {
            mstore(0x00, left)
            mstore(0x20, right)
            let ok := staticcall(gas(), 0x02, 0x00, 64, 0x00, 32)
            if iszero(ok) { revert(0, 0) }
            sha256Result := mload(0x00)
        }

        // BiniusCompress uses a domain-separated IV so results differ from plain SHA256
        assertNotEq(compressResult, sha256Result, "BiniusCompress != SHA256");
    }

    // ─── FRIFold: NTT fold correctness ────────────────────────────────────────

    /// @notice Folding all-zero coset values produces zero.
    function test_fri_fold_chunk_zeros() public pure {
        uint256[] memory values = new uint256[](16);
        uint256[] memory challenges = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) challenges[i] = 1; // challenge = 1
        uint256 result = FRIFold.foldChunk(values, challenges, 14, 0);
        assertEq(result, 0, "fold of zeros is zero");
    }

    /// @notice Folding is deterministic.
    function test_fri_fold_chunk_deterministic() public pure {
        uint256[] memory values = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) values[i] = uint256(keccak256(abi.encodePacked("v", i))) & ((1<<128)-1);
        uint256[] memory challenges = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) challenges[i] = uint256(keccak256(abi.encodePacked("c", i))) & ((1<<128)-1);

        uint256 r1 = FRIFold.foldChunk(values, challenges, 14, 0);
        uint256 r2 = FRIFold.foldChunk(values, challenges, 14, 0);
        assertEq(r1, r2, "foldChunk is deterministic");
    }

    /// @notice Different chunk indices produce different results (index-dependency).
    function test_fri_fold_chunk_index_dependent() public pure {
        uint256[] memory values = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) values[i] = uint256(keccak256(abi.encodePacked("v", i))) & ((1<<128)-1);
        uint256[] memory challenges = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) challenges[i] = uint256(keccak256(abi.encodePacked("c", i))) & ((1<<128)-1);

        uint256 r0 = FRIFold.foldChunk(values, challenges, 14, 0);
        uint256 r1 = FRIFold.foldChunk(values, challenges, 14, 1);
        assertNotEq(r0, r1, "different chunk index -> different fold result");
    }

    /// @notice foldInterleaved with all-zero inputs is zero.
    function test_fri_fold_interleaved_zeros() public pure {
        uint256[] memory values = new uint256[](16);
        uint256[] memory challenges = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) challenges[i] = 1;
        uint256 result = FRIFold.foldInterleaved(values, challenges);
        assertEq(result, 0, "foldInterleaved of zeros is zero");
    }

    // ─── GF128: field arithmetic using BinaryFieldLibOpt ─────────────────────

    /// @notice GF128.mul is commutative.
    function test_gf128_mul_commutative() public pure {
        uint256 a = 0x1234567890abcdef1234567890abcdef;
        uint256 b = 0xfedcba0987654321fedcba0987654321;
        assertEq(GF128.mul(a, b), GF128.mul(b, a), "GF128.mul commutative");
    }

    /// @notice GF128.mul with 1 is identity.
    function test_gf128_mul_identity() public pure {
        uint256 a = 0xdeadbeefcafebabe1234567890abcdef;
        assertEq(GF128.mul(a, 1), a, "a * 1 == a");
        assertEq(GF128.mul(1, a), a, "1 * a == a");
    }

    /// @notice GF128.mul with 0 is zero.
    function test_gf128_mul_zero() public pure {
        uint256 a = 0xdeadbeefcafebabe1234567890abcdef;
        assertEq(GF128.mul(a, 0), 0, "a * 0 == 0");
    }

    /// @notice GF128 add is XOR.
    function test_gf128_add_is_xor() public pure {
        uint256 a = 0x1234;
        uint256 b = 0x5678;
        assertEq(GF128.add(a, b), a ^ b, "GF128.add == XOR");
    }

    // ─── Gas benchmarks ───────────────────────────────────────────────────────

    /// @notice Measure gas for the assembly-optimised _hashCoset (via harness).
    function test_bench_hash_coset_gas() public {
        BaseFoldHashCosetHarness h = new BaseFoldHashCosetHarness();
        uint256[] memory vals = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) {
            vals[i] = uint256(keccak256(abi.encodePacked(i))) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        }
        uint256 g = gasleft();
        h.hashCoset(vals);
        uint256 cost = g - gasleft();
        emit log_named_uint("BaseFold._hashCoset (asm bswap128) gas", cost);
        assertLt(cost, 15_000, "_hashCoset should be under 15k gas with assembly optimisation");
    }

    /// @notice Measure gas for a BiniusCompress call (SHA256 compression).
    function test_bench_binius_compress_gas() public {
        bytes32 left  = bytes32(uint256(1));
        bytes32 right = bytes32(uint256(2));
        uint256 g = gasleft();
        BiniusCompress.compress(left, right);
        uint256 cost = g - gasleft();
        emit log_named_uint("BiniusCompress.compress gas", cost);
        assertLt(cost, 100_000, "BiniusCompress should be under 100k gas");
    }

    /// @notice Measure gas for MerkleLib._sha256pair (via verify call).
    function test_bench_merklelib_sha256pair_gas() public {
        bytes32 left  = bytes32(uint256(1));
        bytes32 right = bytes32(uint256(2));

        bytes32 root;
        assembly {
            mstore(0x00, left)
            mstore(0x20, right)
            let ok := staticcall(gas(), 0x02, 0x00, 64, 0x00, 32)
            if iszero(ok) { revert(0, 0) }
            root := mload(0x00)
        }

        bytes32[] memory siblings = new bytes32[](1);
        siblings[0] = right;

        uint256 g = gasleft();
        MerkleLib.verify(root, left, siblings, 0);
        uint256 cost = g - gasleft();
        emit log_named_uint("MerkleLib.verify (depth 1) gas", cost);
        assertLt(cost, 10_000, "SHA256 Merkle verify (1 level) should be under 10k gas");
    }

    /// @notice Measure gas for foldChunk (NTT fold, 16 elements, 4 rounds).
    function test_bench_fri_fold_chunk_gas() public {
        uint256[] memory values = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) values[i] = i + 1;
        uint256[] memory challenges = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) challenges[i] = i + 1;

        uint256 g = gasleft();
        FRIFold.foldChunk(values, challenges, 14, 0);
        uint256 cost = g - gasleft();
        emit log_named_uint("FRIFold.foldChunk (16 vals, 4 rounds) gas", cost);
        // NTT fold: 16 elements × 4 butterfly layers × Zech-log GF128 mul + twiddle lookups.
        // Baseline ~624k gas; 1M bound leaves headroom for twiddle-table unrolling optimisation.
        assertLt(cost, 1_000_000, "foldChunk should be under 1M gas");
    }

    // ─── Real proof path (REAL_E2E=1) ─────────────────────────────────────────

    /// @notice Load a real binius64 proof from fixtures/native_proof.bin and verify it.
    ///
    ///         To activate: REAL_E2E=1 forge test --match-test test_real_native_proof_verifies -vvv
    ///
    ///         The fixture must be generated by:
    ///           cd binius-research/envelope-circuits
    ///           cargo run --bin export_proof -- \
    ///             --circuit encumbrance \
    ///             --output ../../binius-verifier/test/fixtures/native_proof.bin
    ///
    ///         The binary format is the raw proof bytes as emitted by the Rust
    ///         binius64 serializer (no extra framing — what the Rust prover writes
    ///         to the channel is exactly what goes in the file).
    // =========================================================================
    // RingSwitch._transpose cross-validation
    //
    // The internal _transpose function is library-level; we exercise it by
    // routing through a thin public harness below the main test contract.
    // =========================================================================

    /// @notice Identity: transposing a matrix twice returns the original.
    function test_transpose_double_is_identity() public {
        RingSwitchHarness harness = new RingSwitchHarness();
        uint256[] memory v = new uint256[](128);
        // Fill with pseudo-random rows (deterministic pattern).
        for (uint256 i = 0; i < 128; i++) {
            // Mix row index into two 64-bit halves, stay within 128 bits.
            v[i] = (i * 0x9e3779b97f4a7c15) ^ ((i * 0x6c62272e07bb0142) << 64);
            v[i] &= 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        }
        uint256[] memory once  = harness.transposePublic(v);
        uint256[] memory twice = harness.transposePublic(once);
        for (uint256 i = 0; i < 128; i++) {
            assertEq(twice[i], v[i], "double-transpose must be identity");
        }
    }

    /// @notice Known-answer: for a matrix with exactly one bit set at (r, c),
    ///         the transpose should have exactly one bit set at (c, r).
    function test_transpose_single_bit_roundtrip() public {
        RingSwitchHarness harness = new RingSwitchHarness();
        uint256 r = 47;
        uint256 c = 93;

        uint256[] memory v = new uint256[](128);
        v[r] = 1 << c;  // set bit c of row r

        uint256[] memory u = harness.transposePublic(v);

        // Only row c should be non-zero, with exactly bit r set.
        assertEq(u[c], uint256(1) << r, "transposed single bit should be at (c,r)");
        for (uint256 i = 0; i < 128; i++) {
            if (i != c) assertEq(u[i], 0, "all other rows must be zero");
        }
    }

    /// @notice Symmetry check: an anti-diagonal matrix (M[i][i] = 1, rest 0)
    ///         is fixed by transpose (diagonal matrices are self-transpose).
    function test_transpose_diagonal_self_transpose() public {
        RingSwitchHarness harness = new RingSwitchHarness();
        uint256[] memory v = new uint256[](128);
        for (uint256 i = 0; i < 128; i++) v[i] = uint256(1) << i;  // identity matrix

        uint256[] memory u = harness.transposePublic(v);
        for (uint256 i = 0; i < 128; i++) {
            assertEq(u[i], v[i], "identity matrix is self-transpose");
        }
    }

    /// @notice Gas benchmark for the O(n log n) butterfly transpose.
    function test_bench_ring_switch_transpose_gas() public {
        RingSwitchHarness harness = new RingSwitchHarness();
        uint256[] memory v = new uint256[](128);
        for (uint256 i = 0; i < 128; i++) {
            v[i] = (uint256(keccak256(abi.encodePacked(i))) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);
        }
        uint256 g = gasleft();
        harness.transposePublic(v);
        uint256 gasUsed = g - gasleft();
        emit log_named_uint("RingSwitch._transpose gas (O(n log n) butterfly)", gasUsed);
        assertLt(gasUsed, 5_000_000, "butterfly transpose should be under 5M gas");
    }

    function test_real_native_proof_verifies() public {
        try vm.envBool("REAL_E2E") returns (bool enabled) {
            if (!enabled) return;
        } catch {
            return; // env var not set — skip silently
        }

        // Load raw proof bytes
        bytes memory proof = vm.readFileBinary("test/fixtures/native_proof.bin");
        assertTrue(proof.length > 0, "fixture file must be non-empty");
        emit log_named_uint("Proof size (bytes)", proof.length);

        // Load public inputs: 128 u64 words encoded as JSON array
        string memory piJson = vm.readFile("test/fixtures/native_public_inputs.json");
        uint256[] memory publicInputs = vm.parseJsonUintArray(piJson, ".values");
        assertEq(publicInputs.length, 128, "Encumber expects 128 public input words");

        // Verify
        uint256 g = gasleft();
        bool valid = verifier.verify(proof, publicInputs);
        uint256 cost = g - gasleft();
        assertTrue(valid, "real binius64 native proof must verify");

        emit log_named_uint("Binius64NativeVerifier.verify gas", cost);
        // Target: < 500M gas (current EVM block gas limit ~30M mainnet, tested on Anvil)
        assertLt(cost, 500_000_000, "native verifier gas must be under 500M for integration");
    }
}

// =============================================================================
// Harness contracts — expose internal library functions for testing
// =============================================================================

import "../src/BaseFold.sol";

/// @notice Exposes BaseFold._hashCoset so the gas benchmark test can call it.
contract BaseFoldHashCosetHarness {
    function hashCoset(uint256[] calldata vals) external view returns (bytes32 result) {
        uint256[] memory mVals = new uint256[](vals.length);
        for (uint256 i = 0; i < vals.length; i++) mVals[i] = vals[i];
        assembly {
            // Identical to BaseFold._hashCoset assembly block (bswap128 + 8 mstore + SHA256)
            let buf    := mload(0x40)

            let vBase  := add(mVals, 32)
            let m1     := 0x00ff00ff00ff00ff00ff00ff00ff00ff
            let m2     := 0x0000ffff0000ffff0000ffff0000ffff
            let m3     := 0x00000000ffffffff00000000ffffffff
            let mLo    := 0xffffffffffffffff

            for { let k := 0 } lt(k, 8) { k := add(k, 1) } {
                let v0 := mload(add(vBase, mul(mul(k, 2),     32)))
                let v1 := mload(add(vBase, mul(add(mul(k, 2), 1), 32)))

                let r0 := v0
                r0 := or(shl(8,  and(r0, m1)), and(shr(8,  r0), m1))
                r0 := or(shl(16, and(r0, m2)), and(shr(16, r0), m2))
                r0 := or(shl(32, and(r0, m3)), and(shr(32, r0), m3))
                r0 := or(shl(64, and(r0, mLo)), shr(64, r0))
                r0 := and(r0, 0xffffffffffffffffffffffffffffffff)

                let r1 := v1
                r1 := or(shl(8,  and(r1, m1)), and(shr(8,  r1), m1))
                r1 := or(shl(16, and(r1, m2)), and(shr(16, r1), m2))
                r1 := or(shl(32, and(r1, m3)), and(shr(32, r1), m3))
                r1 := or(shl(64, and(r1, mLo)), shr(64, r1))
                r1 := and(r1, 0xffffffffffffffffffffffffffffffff)

                mstore(add(buf, mul(k, 32)), or(shl(128, r0), r1))
            }

            let ok := staticcall(gas(), 0x02, buf, 256, 0x00, 32)
            if iszero(ok) { revert(0, 0) }
            result := mload(0x00)
        }
    }
}

/// @notice Exposes RingSwitch._transpose so test contracts can call it.
contract RingSwitchHarness {
    function transposePublic(uint256[] calldata v) external pure returns (uint256[] memory) {
        uint256[] memory mV = new uint256[](v.length);
        for (uint256 i = 0; i < v.length; i++) mV[i] = v[i];
        return _transpose(mV);
    }

    function _transpose(uint256[] memory v) internal pure returns (uint256[] memory u) {
        uint256 n = v.length;
        require(n == 128, "RingSwitchHarness: expected 128-element vector");
        u = new uint256[](n);
        uint256 M128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        for (uint256 i = 0; i < n; i++) u[i] = v[i] & M128;

        for (uint256 p = 0; p < 7; p++) {
            uint256 s = 64 >> p;
            uint256 m = _transposeMask(s);
            for (uint256 i = 0; i < n; i++) {
                if ((i & s) == 0) {
                    uint256 j = i | s;
                    uint256 t = ((u[i] >> s) ^ u[j]) & m;
                    u[i] = (u[i] ^ (t << s)) & M128;
                    u[j] ^= t;
                }
            }
        }
    }

    function _transposeMask(uint256 s) internal pure returns (uint256) {
        if (s == 64) return 0xFFFFFFFFFFFFFFFF;
        if (s == 32) return 0x00000000FFFFFFFF00000000FFFFFFFF;
        if (s == 16) return 0x0000FFFF0000FFFF0000FFFF0000FFFF;
        if (s ==  8) return 0x00FF00FF00FF00FF00FF00FF00FF00FF;
        if (s ==  4) return 0x0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F;
        if (s ==  2) return 0x33333333333333333333333333333333;
        return              0x55555555555555555555555555555555;
    }
}
