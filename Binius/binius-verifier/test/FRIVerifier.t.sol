// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/BinaryFieldLib.sol";
import "../src/FRIVerifier.sol";
import "../src/FiatShamirTranscript.sol";
import "../src/MerkleVerifier.sol";
import "../src/SumcheckVerifier.sol";

/// @notice Tests for FRIVerifier — both correctness (happy path) and
///         negative tests (tampered proofs must be rejected).
///
/// Negative tests are the primary security contribution of this file.
/// Each test:
///   1. Constructs a valid proof
///   2. Mutates exactly ONE field
///   3. Asserts the verifier returns false (or reverts)
///
/// This directly addresses the reviewer concern: "A valid-looking proof for
/// a false statement should be rejected."
///
/// Note on vm.expectRevert: Foundry's expectRevert only intercepts reverts
/// from EXTERNAL calls. Internal library calls (even if they require-revert)
/// happen at the same call depth as the test. The external helper functions
/// prefixed with `ext_` below exist solely as callable external entry points
/// so that vm.expectRevert can intercept the revert at the correct depth.
contract FRIVerifierTest is Test {
    using FiatShamirTranscript for FiatShamirTranscript.Transcript;
    using BinaryFieldLib for uint256;

    // -----------------------------------------------------------------------
    //  External wrappers (vm.expectRevert requires external call depth)
    // -----------------------------------------------------------------------

    function ext_sumcheck_verify(
        SumcheckVerifier.SumcheckClaim memory claim,
        SumcheckVerifier.SumcheckProof memory proof
    ) external pure {
        FiatShamirTranscript.Transcript memory t = FiatShamirTranscript.init();
        SumcheckVerifier.verify(claim, proof, t);
    }

    function ext_fri_verify(
        bytes32 initialRoot,
        FRIVerifier.FRIProof memory proof,
        FRIVerifier.FRIParams memory params
    ) external pure returns (bool) {
        FiatShamirTranscript.Transcript memory t = FiatShamirTranscript.init();
        return FRIVerifier.verify(initialRoot, proof, params, t);
    }

    // -----------------------------------------------------------------------
    //  binaryFold unit tests
    // -----------------------------------------------------------------------

    /// @dev binaryFold(y0, y1, alpha, sInv=1) = y0 XOR (alpha MUL (y0 XOR y1))
    ///      This is the correct binary-field fold for a normalized domain.
    function test_binaryFold_zero_alpha_returns_y0() public pure {
        uint256 y0 = 0xABCDEF;
        uint256 y1 = 0x123456;
        uint256 alpha = 0; // no correction
        uint256 result = FRIVerifier.binaryFold(y0, y1, alpha, 1);
        assertEq(result, y0, "alpha=0 should return y0 unchanged");
    }

    function test_binaryFold_alpha_one_equal_values_returns_y0() public pure {
        // If y0 == y1, diff = y0 XOR y1 = 0, so fold = y0 + alpha*0 = y0.
        uint256 y = 0xDEADBEEF;
        uint256 result = FRIVerifier.binaryFold(y, y, 1, 1);
        assertEq(result, y, "equal values: fold should return y0");
    }

    function test_binaryFold_known_values() public pure {
        // fold(5, 3, 2, sInv=1):
        //   diff = 5 XOR 3 = 6
        //   normalizedDiff = mulGF2_128(6, 1) = 6
        //   correction = mulGF2_128(2, 6) = 12 (binary: 0b110 * 0b10 = 0b1100 in GF(2)[x])
        //   result = 5 XOR 12 = 9
        // In binary (GF(2^128), no carries):
        //   mulGF2_128(2, 6): at GF(2^2) level, a=2(=0b10), b=6(=0b110)...
        //   Let's compute via the library directly and just verify consistency.
        uint256 y0 = 5;
        uint256 y1 = 3;
        uint256 alpha = 2;
        uint256 folded = FRIVerifier.binaryFold(y0, y1, alpha, 1);

        // Manually verify: folded = y0 XOR (alpha MUL (y0 XOR y1))
        uint256 expected = y0 ^ BinaryFieldLib.mulGF2_128(alpha, y0 ^ y1);
        assertEq(folded, expected, "fold should match manual calculation");
    }

    function test_binaryFold_sInv_scales_correction() public pure {
        uint256 y0 = 0xFF;
        uint256 y1 = 0x0F;
        uint256 alpha = 0x03;
        // sInv=1 vs sInv≠1 should give different results
        uint256 fold1 = FRIVerifier.binaryFold(y0, y1, alpha, 1);
        uint256 fold2 = FRIVerifier.binaryFold(y0, y1, alpha, 2);
        assertTrue(fold1 != fold2, "different sInv must give different fold");
    }

    // -----------------------------------------------------------------------
    //  MerkleVerifier negative tests
    // -----------------------------------------------------------------------

    function test_merkle_rejects_wrong_root() public pure {
        uint256 leaf0Val = 0xABCDEF;
        uint256 leaf1Val = 0x123456;
        bytes32 leaf0 = MerkleVerifier.hashLeaf(leaf0Val);
        bytes32 leaf1 = MerkleVerifier.hashLeaf(leaf1Val);
        bytes32 realRoot = keccak256(abi.encodePacked(leaf0, leaf1));
        bytes32 wrongRoot = bytes32(uint256(realRoot) ^ 1); // flip LSB

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf1;

        bool valid = MerkleVerifier.verifyProof(wrongRoot, leaf0, 0, proof);
        assertFalse(valid, "Wrong root must be rejected");
    }

    function test_merkle_rejects_wrong_leaf() public pure {
        uint256 leaf0Val = 0xABCDEF;
        uint256 leaf1Val = 0x123456;
        bytes32 leaf0 = MerkleVerifier.hashLeaf(leaf0Val);
        bytes32 leaf1 = MerkleVerifier.hashLeaf(leaf1Val);
        bytes32 root = keccak256(abi.encodePacked(leaf0, leaf1));

        bytes32 wrongLeaf = bytes32(uint256(leaf0) ^ 1);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf1;

        bool valid = MerkleVerifier.verifyProof(root, wrongLeaf, 0, proof);
        assertFalse(valid, "Wrong leaf hash must be rejected");
    }

    function test_merkle_rejects_wrong_sibling() public pure {
        uint256 leaf0Val = 0xABCDEF;
        uint256 leaf1Val = 0x123456;
        bytes32 leaf0 = MerkleVerifier.hashLeaf(leaf0Val);
        bytes32 leaf1 = MerkleVerifier.hashLeaf(leaf1Val);
        bytes32 root = keccak256(abi.encodePacked(leaf0, leaf1));

        bytes32[] memory tampered = new bytes32[](1);
        tampered[0] = bytes32(uint256(leaf1) ^ 1); // corrupt sibling

        bool valid = MerkleVerifier.verifyProof(root, leaf0, 0, tampered);
        assertFalse(valid, "Corrupted sibling must be rejected");
    }

    function test_merkle_accepts_valid_proof_index0() public pure {
        uint256 leaf0Val = 0xABCDEF;
        uint256 leaf1Val = 0x123456;
        bytes32 leaf0 = MerkleVerifier.hashLeaf(leaf0Val);
        bytes32 leaf1 = MerkleVerifier.hashLeaf(leaf1Val);
        bytes32 root = keccak256(abi.encodePacked(leaf0, leaf1));

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf1;
        assertTrue(MerkleVerifier.verifyProof(root, leaf0, 0, proof), "Valid proof for index 0");
    }

    function test_merkle_accepts_valid_proof_index1() public pure {
        uint256 leaf0Val = 0xABCDEF;
        uint256 leaf1Val = 0x123456;
        bytes32 leaf0 = MerkleVerifier.hashLeaf(leaf0Val);
        bytes32 leaf1 = MerkleVerifier.hashLeaf(leaf1Val);
        bytes32 root = keccak256(abi.encodePacked(leaf0, leaf1));

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf0; // for index 1, sibling is leaf0 (left)
        assertTrue(MerkleVerifier.verifyProof(root, leaf1, 1, proof), "Valid proof for index 1");
    }

    // -----------------------------------------------------------------------
    //  SumcheckVerifier negative tests
    // -----------------------------------------------------------------------

    function test_sumcheck_rejects_wrong_claimed_sum() public {
        SumcheckVerifier.RoundPoly memory round;
        round.coeffs[0] = 0x42; // g(0) = 0x42
        round.coeffs[1] = 0xFF; // g(1) = 0x42 ^ 0xFF = 0xBD; sum = 0x42 ^ 0xBD = 0xFF
        round.coeffs[2] = 0;
        round.coeffs[3] = 0;

        SumcheckVerifier.SumcheckProof memory proof;
        proof.rounds = new SumcheckVerifier.RoundPoly[](1);
        proof.rounds[0] = round;

        // Correct sum is 0xFF. Supply 0xAB (wrong).
        SumcheckVerifier.SumcheckClaim memory claim = SumcheckVerifier.SumcheckClaim({
            claimedSum: 0xAB,
            numVariables: 1
        });

        vm.expectRevert("SumcheckVerifier: round check failed");
        this.ext_sumcheck_verify(claim, proof);
    }

    function test_sumcheck_rejects_corrupted_round_poly() public {
        // In GF(2): sum = g(0) ^ g(1) = c0 ^ (c0^c1^c2^c3) = c1^c2^c3.
        // Corrupting c0 alone does NOT change the sum. To produce a sum mismatch,
        // corrupt c1 (which directly contributes to the sum).
        SumcheckVerifier.RoundPoly memory round;
        round.coeffs[0] = 0;
        round.coeffs[1] = 0xFF; // sum = 0xFF ^ 0 ^ 0 = 0xFF
        round.coeffs[2] = 0;
        round.coeffs[3] = 0;

        SumcheckVerifier.SumcheckProof memory proof;
        proof.rounds = new SumcheckVerifier.RoundPoly[](1);
        proof.rounds[0] = round;

        // Tamper with c1: 0xFF → 0xFE. New sum = 0xFE ^ 0 ^ 0 = 0xFE ≠ 0xFF.
        proof.rounds[0].coeffs[1] = 0xFE;

        SumcheckVerifier.SumcheckClaim memory claim = SumcheckVerifier.SumcheckClaim({
            claimedSum: 0xFF,
            numVariables: 1
        });

        vm.expectRevert("SumcheckVerifier: round check failed");
        this.ext_sumcheck_verify(claim, proof);
    }

    function test_sumcheck_rejects_wrong_round_count() public {
        // Claim 2 variables but supply only 1 round
        SumcheckVerifier.RoundPoly memory round;
        round.coeffs[0] = 0;
        round.coeffs[1] = 1;
        round.coeffs[2] = 0;
        round.coeffs[3] = 0;

        SumcheckVerifier.SumcheckProof memory proof;
        proof.rounds = new SumcheckVerifier.RoundPoly[](1); // only 1 round
        proof.rounds[0] = round;

        SumcheckVerifier.SumcheckClaim memory claim = SumcheckVerifier.SumcheckClaim({
            claimedSum: 1,
            numVariables: 2 // claims 2 variables
        });

        vm.expectRevert("SumcheckVerifier: wrong number of rounds");
        this.ext_sumcheck_verify(claim, proof);
    }

    // -----------------------------------------------------------------------
    //  FRI verify — minimal end-to-end positive + negative test
    //
    //  We construct a 1-round FRI proof over a 2-element initial domain:
    //    - initial evaluations: [v0, v1] at indices [0, 1]
    //    - 1 folding round: fold(v0, v1, alpha) → finalPoly
    //    - 1 query (index 0)
    //
    //  The Fiat-Shamir transcript is driven identically to the verifier:
    //    absorb(commitment[0].merkleRoot) → alpha
    //    squeeze → queryIndex (% 2)
    // -----------------------------------------------------------------------

    /// @dev Build a valid 1-round FRI proof and return it together with the
    ///      initial root and params, for use in positive and negative tests.
    function _buildMinimalFRIProof(
        uint256 v0,
        uint256 v1
    ) internal pure returns (
        bytes32 initialRoot,
        FRIVerifier.FRIProof memory proof,
        FRIVerifier.FRIParams memory params
    ) {
        // Build initial Merkle tree: 2 leaves
        bytes32 leaf0 = MerkleVerifier.hashLeaf(v0);
        bytes32 leaf1 = MerkleVerifier.hashLeaf(v1);
        initialRoot = keccak256(abi.encodePacked(leaf0, leaf1));

        // The folded polynomial is a single constant: fold(v0, v1, alpha).
        // Its "Merkle root" (for 1 element) is just the hash of that value.
        // We need to determine alpha first via the transcript.

        // Simulate the Fiat-Shamir transcript to get alpha:
        FiatShamirTranscript.Transcript memory sim = FiatShamirTranscript.init();
        // The commitment[0] is the root of the FOLDED (1-element) polynomial.
        // But alpha must be squeezed AFTER absorbing commitment[0]. This is
        // a chicken-and-egg: the fold value depends on alpha, but alpha depends
        // on the commitment root, which is the hash of the fold value.
        //
        // We must fix the commitment root first, then derive alpha consistently.
        // In practice the prover runs: fold → commit → transcript absorb → queries.
        //
        // For testing: choose an arbitrary commitment root for commitment[0].
        // The verifier checks Merkle proofs against commitment[r-1] for r>=1.
        // For the LAST folding round (r == numFoldingRounds-1 == 0), the
        // verifier checks against initialRoot. So commitment[0] is NOT checked
        // against any Merkle proof in a 1-round proof — it's only absorbed into
        // the transcript to bind the prover's folded polynomial.
        //
        // For a 1-round proof with 1 query, commitment[0] is only transcript-bound.
        // We pick commitment[0] = hash(fold_value) and verify no Merkle check occurs.

        // Step 1: pick a dummy transcript-only commitment root.
        // (We compute the fold below after getting alpha.)
        // To bootstrap: choose commitment[0] as some fixed value,
        // compute alpha from it, compute fold, verify fold == expected.

        // Use a two-pass simulation: first compute alpha from a placeholder,
        // then use that alpha to compute fold, set commitment[0] = hash(fold).
        // Then recompute alpha from the correct commitment — in general these
        // disagree unless we iterate. Instead, we use a self-consistent approach:

        // Self-consistent construction:
        //   We want: commitment[0] = keccak256(fold(v0, v1, alpha, 1))
        //            alpha = first_squeeze(transcript.absorb(commitment[0]))
        //   This is a fixed-point equation. In practice the prover solves it by
        //   committing first, then running the transcript in order.
        //   For tests we fix commitment[0] = bytes32(keccak256("test-commit")) as
        //   a constant. The verifier only absorbs it for the transcript; since there
        //   is only 1 query and 1 round, the only Merkle check is against initialRoot.
        bytes32 foldCommit = keccak256("test-fold-commit");
        sim.absorbBytes32(foldCommit);
        uint256 alpha = sim.squeeze128();

        // Step 2: compute the fold value with the derived alpha
        uint256 foldedVal = FRIVerifier.binaryFold(v0, v1, alpha, 1);

        // Step 3: determine query index
        uint256 rawQ = sim.squeeze128();
        uint256 domainSize = 2; // logDomainSize = 1
        uint256 queryIdx = rawQ % domainSize;

        // Step 4: build Merkle proof for the query
        // For index 0: val0=v0, val1=v1, proof=[leaf1]
        // For index 1: val0=v0, val1=v1 with idx flipped — but we need val at queryIdx
        // Looking at _verifyQueryRound:
        //   half = 1 << (logSize - 1) = 1
        //   idx0 = queryIdx < half ? queryIdx : queryIdx - half
        //        = queryIdx < 1 ? queryIdx : queryIdx - 1
        //   For queryIdx=0: idx0=0, idx1=1
        //   For queryIdx=1: idx0=0 (since 1 >= 1, 1-1=0), idx1=1
        // Both cases: idx0=0, idx1=1, val0=v0, val1=v1
        // Merkle proof for idx0=0: sibling = leaf1
        // Merkle proof for idx1=1: sibling = leaf0
        bytes32[] memory merkleProof0 = new bytes32[](1);
        bytes32[] memory merkleProof1 = new bytes32[](1);
        merkleProof0[0] = leaf1; // proof for idx0=0
        merkleProof1[0] = leaf0; // proof for idx1=1

        // Build the proof struct
        proof.commitments = new FRIVerifier.FRIRoundCommitment[](1);
        proof.commitments[0].merkleRoot = foldCommit;

        proof.queries = new FRIVerifier.FRIQuery[](1);
        proof.queries[0].queryIndex = queryIdx;
        proof.queries[0].rounds = new FRIVerifier.FRIQueryRound[](1);
        proof.queries[0].rounds[0].val0 = v0;
        proof.queries[0].rounds[0].val1 = v1;
        proof.queries[0].rounds[0].merkleProof0 = merkleProof0;
        proof.queries[0].rounds[0].merkleProof1 = merkleProof1;
        proof.queries[0].finalValue = foldedVal;
        proof.finalPoly = foldedVal;

        params.numFoldingRounds = 1;
        params.numQueries = 1;
        params.logDomainSize = 1;
    }

    function test_fri_minimal_valid_proof_passes() public pure {
        uint256 v0 = 0xABCDEF12345678;
        uint256 v1 = 0x87654321FEDCBA;

        (
            bytes32 initialRoot,
            FRIVerifier.FRIProof memory proof,
            FRIVerifier.FRIParams memory params
        ) = _buildMinimalFRIProof(v0, v1);

        FiatShamirTranscript.Transcript memory transcript = FiatShamirTranscript.init();
        bool valid = FRIVerifier.verify(initialRoot, proof, params, transcript);
        assertTrue(valid, "Valid minimal FRI proof should pass");
    }

    function test_fri_rejects_corrupted_val0() public pure {
        uint256 v0 = 0xABCDEF12345678;
        uint256 v1 = 0x87654321FEDCBA;

        (
            bytes32 initialRoot,
            FRIVerifier.FRIProof memory proof,
            FRIVerifier.FRIParams memory params
        ) = _buildMinimalFRIProof(v0, v1);

        // Corrupt val0 — Merkle proof for this value will fail
        proof.queries[0].rounds[0].val0 ^= 1;

        FiatShamirTranscript.Transcript memory transcript = FiatShamirTranscript.init();
        bool valid = FRIVerifier.verify(initialRoot, proof, params, transcript);
        assertFalse(valid, "Corrupted val0 must be rejected (Merkle proof fails)");
    }

    function test_fri_rejects_corrupted_val1() public pure {
        uint256 v0 = 0xABCDEF12345678;
        uint256 v1 = 0x87654321FEDCBA;

        (
            bytes32 initialRoot,
            FRIVerifier.FRIProof memory proof,
            FRIVerifier.FRIParams memory params
        ) = _buildMinimalFRIProof(v0, v1);

        // Corrupt val1 — Merkle proof for val1 will fail
        proof.queries[0].rounds[0].val1 ^= 1;

        FiatShamirTranscript.Transcript memory transcript = FiatShamirTranscript.init();
        bool valid = FRIVerifier.verify(initialRoot, proof, params, transcript);
        assertFalse(valid, "Corrupted val1 must be rejected (Merkle proof fails)");
    }

    function test_fri_rejects_wrong_final_poly() public pure {
        uint256 v0 = 0xABCDEF12345678;
        uint256 v1 = 0x87654321FEDCBA;

        (
            bytes32 initialRoot,
            FRIVerifier.FRIProof memory proof,
            FRIVerifier.FRIParams memory params
        ) = _buildMinimalFRIProof(v0, v1);

        // Corrupt the final polynomial constant — query.finalValue != proof.finalPoly
        proof.finalPoly ^= 1;

        FiatShamirTranscript.Transcript memory transcript = FiatShamirTranscript.init();
        bool valid = FRIVerifier.verify(initialRoot, proof, params, transcript);
        assertFalse(valid, "Wrong final polynomial must be rejected");
    }

    function test_fri_rejects_wrong_query_count() public {
        uint256 v0 = 0xABCDEF12345678;
        uint256 v1 = 0x87654321FEDCBA;

        (
            bytes32 initialRoot,
            FRIVerifier.FRIProof memory proof,
            FRIVerifier.FRIParams memory params
        ) = _buildMinimalFRIProof(v0, v1);

        // Claim 2 queries but only provide 1
        params.numQueries = 2;

        vm.expectRevert("FRI: wrong number of queries");
        this.ext_fri_verify(initialRoot, proof, params);
    }

    function test_fri_rejects_wrong_commitment_count() public {
        uint256 v0 = 0xABCDEF12345678;
        uint256 v1 = 0x87654321FEDCBA;

        (
            bytes32 initialRoot,
            FRIVerifier.FRIProof memory proof,
            FRIVerifier.FRIParams memory params
        ) = _buildMinimalFRIProof(v0, v1);

        // Claim 2 folding rounds but only provide 1 commitment
        params.numFoldingRounds = 2;

        vm.expectRevert("FRI: wrong number of commitments");
        this.ext_fri_verify(initialRoot, proof, params);
    }

    function test_fri_rejects_wrong_initial_root() public pure {
        uint256 v0 = 0xABCDEF12345678;
        uint256 v1 = 0x87654321FEDCBA;

        (
            bytes32 initialRoot,
            FRIVerifier.FRIProof memory proof,
            FRIVerifier.FRIParams memory params
        ) = _buildMinimalFRIProof(v0, v1);

        // Corrupt the initial root — Merkle proofs fail
        bytes32 wrongRoot = bytes32(uint256(initialRoot) ^ 1);

        FiatShamirTranscript.Transcript memory transcript = FiatShamirTranscript.init();
        bool valid = FRIVerifier.verify(wrongRoot, proof, params, transcript);
        assertFalse(valid, "Wrong initial root must be rejected");
    }

    // -----------------------------------------------------------------------
    //  Transcript ordering: absorb-before-squeeze
    // -----------------------------------------------------------------------

    /// @dev Verify that absorbing different commitments produces different alphas,
    ///      ensuring the prover cannot choose the challenge by manipulating
    ///      the commitment after alpha is fixed.
    function test_transcript_ordering_different_commits_give_different_alphas() public pure {
        FiatShamirTranscript.Transcript memory t1 = FiatShamirTranscript.init();
        FiatShamirTranscript.Transcript memory t2 = FiatShamirTranscript.init();

        bytes32 commit1 = keccak256("commit-A");
        bytes32 commit2 = keccak256("commit-B");

        t1.absorbBytes32(commit1);
        t2.absorbBytes32(commit2);

        uint256 alpha1 = t1.squeeze128();
        uint256 alpha2 = t2.squeeze128();

        assertTrue(alpha1 != alpha2, "Different commitments must produce different challenges");
    }

    /// @dev Verify that absorbing the same commitment always gives the same alpha
    ///      (determinism — needed for the verifier to reproduce the prover's transcript).
    function test_transcript_ordering_same_commit_gives_same_alpha() public pure {
        FiatShamirTranscript.Transcript memory t1 = FiatShamirTranscript.init();
        FiatShamirTranscript.Transcript memory t2 = FiatShamirTranscript.init();

        bytes32 commit = keccak256("commit-X");

        t1.absorbBytes32(commit);
        t2.absorbBytes32(commit);

        assertEq(t1.squeeze128(), t2.squeeze128(), "Same commitment must give same challenge");
    }
}
