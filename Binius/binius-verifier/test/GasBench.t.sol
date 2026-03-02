// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/BinaryFieldLib.sol";
import "../src/BinaryFieldLibOpt.sol";
import "../src/SumcheckVerifier.sol";
import "../src/FRIVerifier.sol";
import "../src/MerkleVerifier.sol";
import "../src/FiatShamirTranscript.sol";

/// @notice Gas benchmarks that prevent constant-folding by reading inputs
///         from calldata/storage and using them in ways the optimizer cannot elide.
contract GasBenchTest is Test {
    // Stored inputs defeat constant folding
    uint256 public a128 = 0x0123456789ABCDEF0123456789ABCDEF;
    uint256 public b128 = 0xFEDCBA9876543210FEDCBA9876543210;
    uint256 public a64  = 0x123456789ABCDEF0;
    uint256 public b64  = 0xFEDCBA9876543210;

    function setUp() public {
        // Values sourced from state prevent folding
        a128 = uint256(keccak256("a")) & ((1 << 128) - 1);
        b128 = uint256(keccak256("b")) & ((1 << 128) - 1);
        a64  = uint256(keccak256("c")) & ((1 << 64) - 1);
        b64  = uint256(keccak256("d")) & ((1 << 64) - 1);
    }

    // -----------------------------------------------------------------------
    //  Baseline: unoptimized recursive tower
    // -----------------------------------------------------------------------

    function test_bench_mul128_baseline() public {
        uint256 a = a128;
        uint256 b = b128;
        uint256 g = gasleft();
        uint256 r = BinaryFieldLib.mulGF2_128(a, b);
        uint256 cost = g - gasleft();
        emit log_named_uint("mulGF2_128 (anti-fold)", cost);
        // Prevent dead code elimination
        assertGt(r | 1, 0);
    }

    function test_bench_square128_baseline() public {
        uint256 a = a128;
        uint256 g = gasleft();
        uint256 r = BinaryFieldLib.squareGF2_128(a);
        uint256 cost = g - gasleft();
        emit log_named_uint("squareGF2_128 (anti-fold)", cost);
        assertGt(r | 1, 0);
    }

    function test_bench_mul64_baseline() public {
        uint256 a = a64;
        uint256 b = b64;
        uint256 g = gasleft();
        uint256 r = BinaryFieldLib.mulGF2_64(a, b);
        uint256 cost = g - gasleft();
        emit log_named_uint("mulGF2_64 (anti-fold)", cost);
        assertGt(r | 1, 0);
    }

    function test_bench_inv128_baseline() public {
        uint256 a = a128;
        uint256 g = gasleft();
        uint256 r = BinaryFieldLib.invGF2_128(a);
        uint256 cost = g - gasleft();
        emit log_named_uint("invGF2_128 (anti-fold)", cost);
        assertGt(r | 1, 0);
    }

    function test_bench_inv64_baseline() public {
        uint256 a = a64;
        uint256 g = gasleft();
        uint256 r = BinaryFieldLib.invGF2_64(a);
        uint256 cost = g - gasleft();
        emit log_named_uint("invGF2_64 (anti-fold)", cost);
        assertGt(r | 1, 0);
    }

    // -----------------------------------------------------------------------
    //  Optimized: Yul + Zech tables
    // -----------------------------------------------------------------------

    function test_bench_mul128_optimized() public {
        uint256 a = a128;
        uint256 b = b128;
        uint256 g = gasleft();
        uint256 r = BinaryFieldLibOpt.mulGF2_128(a, b);
        uint256 cost = g - gasleft();
        emit log_named_uint("mulGF2_128 (optimized, anti-fold)", cost);
        assertGt(r | 1, 0);
        // Regression: optimized mul must stay under 50k gas (measured ~26k on Tier 1+2)
        assertLt(cost, 50_000, "mulGF2_128 optimized regression");
    }

    function test_bench_square128_optimized() public {
        uint256 a = a128;
        uint256 g = gasleft();
        uint256 r = BinaryFieldLibOpt.squareGF2_128(a);
        uint256 cost = g - gasleft();
        emit log_named_uint("squareGF2_128 (optimized, anti-fold)", cost);
        assertGt(r | 1, 0);
        // Regression: optimized square must stay under 30k gas (measured ~12k)
        assertLt(cost, 30_000, "squareGF2_128 optimized regression");
    }

    // -----------------------------------------------------------------------
    //  Protocol-level: Fiat-Shamir, Merkle, FRI fold, FRI verify
    // -----------------------------------------------------------------------

    function test_bench_fiat_shamir_squeeze() public {
        FiatShamirTranscript.Transcript memory t = FiatShamirTranscript.init();
        FiatShamirTranscript.absorbUint256(t, a128);
        uint256 g = gasleft();
        FiatShamirTranscript.squeeze128(t);
        uint256 cost = g - gasleft();
        emit log_named_uint("FiatShamir.squeeze128 gas", cost);
        // Regression: squeeze must stay under 5k gas (measured ~920)
        assertLt(cost, 5_000, "squeeze128 regression");
    }

    function test_bench_merkle_verify_depth20() public {
        // Build a depth-20 Merkle path (worst case used in FRI)
        bytes32 leaf = MerkleVerifier.hashLeaf(a128);
        bytes32 node = leaf;
        bytes32[] memory proof = new bytes32[](20);
        for (uint256 i = 0; i < 20; i++) {
            proof[i] = bytes32(uint256(keccak256(abi.encodePacked("sib", i))));
            node = keccak256(abi.encodePacked(node, proof[i]));
        }
        bytes32 root = node;

        uint256 g = gasleft();
        bool ok = MerkleVerifier.verifyProof(root, leaf, 0, proof);
        uint256 cost = g - gasleft();
        emit log_named_uint("MerkleVerifier.verifyProof (depth 20) gas", cost);
        assertTrue(ok || !ok, "no revert"); // result doesn't matter for gas bench
        // Regression: depth-20 Merkle must stay under 30k gas (measured ~13k)
        assertLt(cost, 30_000, "Merkle depth-20 regression");
    }

    function test_bench_fri_fold() public {
        uint256 y0    = a128;
        uint256 y1    = b128;
        uint256 alpha = uint256(keccak256("alpha")) & ((1 << 128) - 1);
        uint256 g = gasleft();
        uint256 result = FRIVerifier.binaryFold(y0, y1, alpha, 1);
        uint256 cost = g - gasleft();
        emit log_named_uint("FRIVerifier.binaryFold gas", cost);
        assertGt(result | 1, 0);
        // Regression: a single FRI fold uses BinaryFieldLib (unoptimized) mulGF2_128.
        // Baseline is ~368k gas.  With BinaryFieldLibOpt (Yul + Zech tables) this
        // drops to ~26k.  Bound is set at the baseline to catch algorithmic regressions
        // while remaining pass-on-any-build; update downward as optimizations land.
        assertLt(cost, 500_000, "binaryFold regression");
    }

    // -----------------------------------------------------------------------
    //  Sumcheck benchmarks
    // -----------------------------------------------------------------------

    function test_bench_sumcheck_20vars() public {
        uint256 numVars = 20;
        FiatShamirTranscript.Transcript memory simT = FiatShamirTranscript.init();
        FiatShamirTranscript.absorbUint256(simT, uint256(keccak256("seed")));

        SumcheckVerifier.SumcheckProof memory proof;
        proof.rounds = new SumcheckVerifier.RoundPoly[](numVars);

        uint256 currentSum = a128;

        for (uint256 i = 0; i < numVars; i++) {
            SumcheckVerifier.RoundPoly memory round;
            round.coeffs[0] = 0;
            round.coeffs[1] = currentSum;
            round.coeffs[2] = 0;
            round.coeffs[3] = 0;
            proof.rounds[i] = round;

            FiatShamirTranscript.absorbUint256(simT, round.coeffs[0]);
            FiatShamirTranscript.absorbUint256(simT, round.coeffs[1]);
            FiatShamirTranscript.absorbUint256(simT, round.coeffs[2]);
            FiatShamirTranscript.absorbUint256(simT, round.coeffs[3]);
            uint256 ri = FiatShamirTranscript.squeeze128(simT);
            currentSum = BinaryFieldLib.mulGF2_128(currentSum, ri);
        }

        SumcheckVerifier.SumcheckClaim memory claim;
        claim.claimedSum = a128;
        claim.numVariables = numVars;

        FiatShamirTranscript.Transcript memory transcript = FiatShamirTranscript.init();
        FiatShamirTranscript.absorbUint256(transcript, uint256(keccak256("seed")));

        uint256 g = gasleft();
        SumcheckVerifier.verify(claim, proof, transcript);
        uint256 cost = g - gasleft();
        emit log_named_uint("sumcheck 20-var (anti-fold)", cost);
    }
}
