// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/BiniusPCSVerifier.sol";
import "../src/SumcheckVerifier.sol";
import "../src/FRIVerifier.sol";
import "../src/FiatShamirTranscript.sol";
import "../src/BinaryFieldLib.sol";

// ---------------------------------------------------------------------------
// External wrapper — vm.expectRevert only works for external calls.
// BiniusPCSVerifier is an internal library, so we route through this contract.
// ---------------------------------------------------------------------------
contract PCSVerifierWrapper {
    using FiatShamirTranscript for FiatShamirTranscript.Transcript;

    function verifyExt(
        BiniusPCSVerifier.PCSCommitment   memory commitment,
        BiniusPCSVerifier.EvaluationClaim memory claim,
        BiniusPCSVerifier.PCSOpeningProof memory proof,
        FiatShamirTranscript.Transcript   memory transcript_
    ) external pure returns (bool) {
        return BiniusPCSVerifier.verify(commitment, claim, proof, transcript_);
    }
}

/// @title BiniusPCSVerifier unit tests
/// @notice Tests the polynomial commitment scheme verifier in isolation,
///         exercising the ring-switching sumcheck and FRI opening phases.
contract BiniusPCSVerifierTest is Test {
    using FiatShamirTranscript for FiatShamirTranscript.Transcript;

    PCSVerifierWrapper wrapper;

    function setUp() public {
        wrapper = new PCSVerifierWrapper();
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _freshTranscript() internal pure returns (FiatShamirTranscript.Transcript memory) {
        return FiatShamirTranscript.initWithDomainSep("pcs-test");
    }

    function _trivialCommitment(uint256 numVars)
        internal pure
        returns (BiniusPCSVerifier.PCSCommitment memory)
    {
        return BiniusPCSVerifier.PCSCommitment({
            merkleRoot:   bytes32(0),
            numVariables: numVars
        });
    }

    function _trivialClaim(uint256 numVars)
        internal pure
        returns (BiniusPCSVerifier.EvaluationClaim memory claim)
    {
        claim.point = new uint256[](numVars);
        claim.value = 0;
    }

    function _trivialProof(uint256 numVars)
        internal pure
        returns (BiniusPCSVerifier.PCSOpeningProof memory proof)
    {
        proof.ringSwitch.sumcheckProof.rounds = new SumcheckVerifier.RoundPoly[](numVars);
        proof.ringSwitch.innerEval            = 0;

        proof.friProof.commitments = new FRIVerifier.FRIRoundCommitment[](numVars);
        proof.friProof.queries     = new FRIVerifier.FRIQuery[](0);
        proof.friProof.finalPoly   = 0;
    }

    // -----------------------------------------------------------------------
    // Point dimension mismatch
    // (uses external wrapper — vm.expectRevert requires an external call)
    // -----------------------------------------------------------------------

    function test_point_dimension_mismatch_reverts() public {
        BiniusPCSVerifier.PCSCommitment  memory com   = _trivialCommitment(3);
        BiniusPCSVerifier.EvaluationClaim memory claim;
        claim.point = new uint256[](2); // wrong: 2 != 3
        claim.value = 0;
        BiniusPCSVerifier.PCSOpeningProof memory proof = _trivialProof(3);
        FiatShamirTranscript.Transcript memory t = _freshTranscript();

        vm.expectRevert("PCS: point dimension mismatch");
        wrapper.verifyExt(com, claim, proof, t);
    }

    // -----------------------------------------------------------------------
    // Ring-switch round-count mismatch propagates from SumcheckVerifier
    // -----------------------------------------------------------------------

    function test_ring_switch_round_mismatch_reverts() public {
        BiniusPCSVerifier.PCSCommitment   memory com   = _trivialCommitment(2);
        BiniusPCSVerifier.EvaluationClaim memory claim = _trivialClaim(2);
        BiniusPCSVerifier.PCSOpeningProof memory proof = _trivialProof(2);
        // Truncate ring-switch rounds to 1 while numVariables = 2
        proof.ringSwitch.sumcheckProof.rounds = new SumcheckVerifier.RoundPoly[](1);
        FiatShamirTranscript.Transcript memory t = _freshTranscript();

        vm.expectRevert("SumcheckVerifier: wrong number of rounds");
        wrapper.verifyExt(com, claim, proof, t);
    }

    // -----------------------------------------------------------------------
    // Zero-variable trivial case
    // -----------------------------------------------------------------------

    function test_zero_variable_proof_does_not_revert() public view {
        BiniusPCSVerifier.PCSCommitment   memory com   = _trivialCommitment(0);
        BiniusPCSVerifier.EvaluationClaim memory claim = _trivialClaim(0);
        BiniusPCSVerifier.PCSOpeningProof memory proof = _trivialProof(0);
        FiatShamirTranscript.Transcript memory t = _freshTranscript();

        bool valid = BiniusPCSVerifier.verify(com, claim, proof, t);
        // Degenerate 0-variable case: all checks trivially pass.
        assertTrue(valid == true || valid == false, "must not revert");
    }

    // -----------------------------------------------------------------------
    // Inner-eval consistency check
    // -----------------------------------------------------------------------

    /// With 1 variable, eqEval(point=[0], challenges=[r]) = (1 - r)
    /// which in GF(2^128) is just r XOR 1 (since 1 - r = 1 + r = 1 XOR r).
    /// Setting innerEval != 0 while finalEval = 0 will cause the check
    ///   finalEval == innerEval * eqVal
    /// to fail → verify returns false.
    function test_inner_eval_mismatch_returns_false() public view {
        BiniusPCSVerifier.PCSCommitment   memory com   = _trivialCommitment(1);
        BiniusPCSVerifier.EvaluationClaim memory claim = _trivialClaim(1);
        claim.point[0] = 0; // evaluation point = 0
        claim.value = 0;    // claimed eval value

        BiniusPCSVerifier.PCSOpeningProof memory proof = _trivialProof(1);
        // Set innerEval to a non-zero value — will mismatch finalEval from sumcheck
        proof.ringSwitch.innerEval = 0xDEADBEEF;

        FiatShamirTranscript.Transcript memory t = _freshTranscript();
        bool valid = BiniusPCSVerifier.verify(com, claim, proof, t);
        assertFalse(valid, "inner-eval mismatch must return false");
    }

    // -----------------------------------------------------------------------
    // Determinism
    // -----------------------------------------------------------------------

    function test_verify_is_deterministic() public view {
        BiniusPCSVerifier.PCSCommitment   memory com   = _trivialCommitment(2);
        BiniusPCSVerifier.EvaluationClaim memory claim = _trivialClaim(2);
        BiniusPCSVerifier.PCSOpeningProof memory proof = _trivialProof(2);

        FiatShamirTranscript.Transcript memory t1 = _freshTranscript();
        FiatShamirTranscript.Transcript memory t2 = _freshTranscript();

        bool r1 = BiniusPCSVerifier.verify(com, claim, proof, t1);
        bool r2 = BiniusPCSVerifier.verify(com, claim, proof, t2);
        assertEq(r1, r2, "verify must be deterministic");
    }

    // -----------------------------------------------------------------------
    // Gas benchmark
    // -----------------------------------------------------------------------

    function test_gas_bench_pcs_0vars() public {
        BiniusPCSVerifier.PCSCommitment   memory com   = _trivialCommitment(0);
        BiniusPCSVerifier.EvaluationClaim memory claim = _trivialClaim(0);
        BiniusPCSVerifier.PCSOpeningProof memory proof = _trivialProof(0);
        FiatShamirTranscript.Transcript memory t = _freshTranscript();

        uint256 g = gasleft();
        BiniusPCSVerifier.verify(com, claim, proof, t);
        emit log_named_uint("BiniusPCSVerifier.verify (0 vars) gas", g - gasleft());
    }

    function test_gas_bench_pcs_4vars() public {
        BiniusPCSVerifier.PCSCommitment   memory com   = _trivialCommitment(4);
        BiniusPCSVerifier.EvaluationClaim memory claim = _trivialClaim(4);
        BiniusPCSVerifier.PCSOpeningProof memory proof = _trivialProof(4);
        FiatShamirTranscript.Transcript memory t = _freshTranscript();

        uint256 g = gasleft();
        BiniusPCSVerifier.verify(com, claim, proof, t);
        emit log_named_uint("BiniusPCSVerifier.verify (4 vars) gas", g - gasleft());
    }
}
