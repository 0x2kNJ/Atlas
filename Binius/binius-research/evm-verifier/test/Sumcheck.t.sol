// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/protocols/Sumcheck.sol";
import "../src/lib/GF128.sol";
import "../src/lib/Transcript.sol";

contract SumcheckTest is Test {
    using GF128 for uint256;
    using Transcript for Transcript.State;

    // ─── Single round ────────────────────────────────────────────────────────

    function test_single_round() public pure {
        // Construct a valid single-round sumcheck via verifyWithArrays.
        // f(x) = a + b*x + c*x^2, sum = f(0)+f(1) = b^c in GF(2)
        uint256 a = 0x42;
        uint256 b = 0xFF;
        uint256 c = 0xAA;
        uint256 claimedSum = b ^ c;

        Sumcheck.RoundPoly[] memory rounds = new Sumcheck.RoundPoly[](1);
        rounds[0] = Sumcheck.RoundPoly(a, b, c);

        uint256[] memory challenges = new uint256[](1);
        challenges[0] = 3;

        uint256 finalEval = Sumcheck.verifyWithArrays(1, claimedSum, rounds, challenges);

        uint256 expected = a ^ GF128.mul(b, 3) ^ GF128.mul(c, GF128.mul(3, 3));
        assertEq(finalEval, expected, "single round final eval");
    }

    // ─── Two rounds ──────────────────────────────────────────────────────────

    function test_two_rounds() public pure {
        // Round 0: coefficients and claimed sum
        uint256 a0 = 0x10;
        uint256 b0 = 0x20;
        uint256 c0 = 0x30;
        uint256 claimedSum = b0 ^ c0; // 0x10

        uint256 alpha0 = 5;
        // eval0 = a0 ^ b0*5 ^ c0*(5*5)
        // 5*5 = GF128.mul(5,5) = in GF(2): x^2*(x^2+1) doesn't apply for small values
        // For small values: 5*5 = 0x19 (x^2+x+1)^2 in polynomial, but let's compute
        uint256 five_sq = GF128.mul(5, 5);
        uint256 eval0 = a0 ^ GF128.mul(b0, alpha0) ^ GF128.mul(c0, five_sq);

        // Round 1: must satisfy b1 ^ c1 = eval0
        uint256 a1 = 0x07;
        uint256 b1_xor_c1 = eval0;
        uint256 b1 = 0x55;
        uint256 c1 = b1 ^ b1_xor_c1; // ensures b1 ^ c1 = eval0

        uint256 alpha1 = 7;

        Sumcheck.RoundPoly[] memory rounds = new Sumcheck.RoundPoly[](2);
        rounds[0] = Sumcheck.RoundPoly(a0, b0, c0);
        rounds[1] = Sumcheck.RoundPoly(a1, b1, c1);

        uint256[] memory challenges = new uint256[](2);
        challenges[0] = alpha0;
        challenges[1] = alpha1;

        uint256 finalEval = Sumcheck.verifyWithArrays(2, claimedSum, rounds, challenges);

        // Manual check of round 1
        uint256 expected = a1 ^ GF128.mul(b1, alpha1) ^ GF128.mul(c1, GF128.mul(alpha1, alpha1));
        assertEq(finalEval, expected, "two round final eval");
    }

    // ─── Wrong sum reverts ───────────────────────────────────────────────────

    function test_wrong_sum_reverts() public {
        SumcheckRevertHelper h = new SumcheckRevertHelper();
        vm.expectRevert("Sumcheck: round check failed");
        h.verifyWrongSum();
    }

    // ─── Transcript-based verify ─────────────────────────────────────────────

    function test_transcript_verify() public view {
        // Build a proof tape with 1 round, degree=2: prover sends [a0, a1] (32 bytes)
        // a2 is recovered: a2 = claimedSum ^ a1
        uint256 a = 0x42;    // a0
        uint256 b = 0xFF;    // a1
        // a2 = claimedSum ^ a1; claimedSum = a1 ^ a2, so choose a2 = 0xAA
        uint256 c = 0xAA;    // a2 (recovered, not sent)
        uint256 claimedSum = b ^ c; // = 0xFF ^ 0xAA = 0x55

        // Proof only sends a0, a1 (NOT a2)
        bytes memory proof = new bytes(32);
        _writeLE128(proof, 0, a);
        _writeLE128(proof, 16, b);

        Transcript.State memory t = Transcript.init(proof);
        Sumcheck.Result memory result = Sumcheck.verify(t, 1, claimedSum);

        assertEq(result.challenges.length, 1);
        assertTrue(result.challenges[0] != 0, "challenge should be nonzero");

        // Verify finalEval matches manual evaluation at the challenge
        uint256 alpha = result.challenges[0];
        uint256 expected = a ^ GF128.mul(b, alpha) ^ GF128.mul(c, GF128.mul(alpha, alpha));
        assertEq(result.finalEval, expected, "transcript-based final eval");
    }

    // ─── Gas benchmark ───────────────────────────────────────────────────────

    function test_bench_sumcheck_8rounds() public {
        // Build a valid 1-round degree-2 proof: prover sends [a0, a1] (32 bytes)
        // a2 = claimedSum ^ a1 is recovered
        uint256 claimedSum = 0x42;
        uint256 a0 = 0;
        uint256 a1 = claimedSum; // a2 will be recovered as claimedSum ^ a1 = 0

        bytes memory proof = new bytes(32);
        _writeLE128(proof, 0, a0);
        _writeLE128(proof, 16, a1);

        Transcript.State memory t = Transcript.init(proof);
        uint256 g0 = gasleft();
        Sumcheck.verify(t, 1, claimedSum);
        uint256 g1 = gasleft();
        emit log_named_uint("Sumcheck.verify(1 round) gas", g0 - g1);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _encodeGF128Triple(uint256 a, uint256 b, uint256 c) internal pure returns (bytes memory) {
        // Encode three GF128 values as 16-byte little-endian each (matching binius wire format)
        bytes memory result = new bytes(48);
        _writeLE128(result, 0, a);
        _writeLE128(result, 16, b);
        _writeLE128(result, 32, c);
        return result;
    }

    function _writeLE128(bytes memory buf, uint256 offset, uint256 val) internal pure {
        for (uint256 i = 0; i < 16; i++) {
            buf[offset + i] = bytes1(uint8(val & 0xFF));
            val >>= 8;
        }
    }
}

contract SumcheckRevertHelper {
    function verifyWrongSum() external pure {
        Sumcheck.RoundPoly[] memory rounds = new Sumcheck.RoundPoly[](1);
        rounds[0] = Sumcheck.RoundPoly(0x42, 0xFF, 0xAA);

        uint256[] memory challenges = new uint256[](1);
        challenges[0] = 3;

        // Wrong claimed sum: should be 0xFF ^ 0xAA = 0x55, but we pass 0x99
        Sumcheck.verifyWithArrays(1, 0x99, rounds, challenges);
    }
}
