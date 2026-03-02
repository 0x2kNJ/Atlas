// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/BinaryFieldLib.sol";
import "../src/BinaryFieldLibOpt.sol";

/// @notice Tests that verify the optimized library matches the reference implementation,
///         and benchmark the gas improvement.
contract BinaryFieldLibOptTest is Test {
    uint256 public a128;
    uint256 public b128;

    function setUp() public {
        a128 = uint256(keccak256("a")) & ((1 << 128) - 1);
        b128 = uint256(keccak256("b")) & ((1 << 128) - 1);
    }

    // -----------------------------------------------------------------------
    //  GF(2^8) table multiply correctness
    // -----------------------------------------------------------------------

    function test_mulGF256_table_matches_reference() public {
        // Sample 512 pairs rather than all 65536 (GenTables.t.sol verified exhaustively)
        for (uint256 a = 0; a < 256; a += 4) {
            for (uint256 b = 0; b < 256; b += 2) {
                uint256 ref = BinaryFieldLib.mulGF256(a, b);
                uint256 opt = BinaryFieldLibOpt.mulGF256_table(a, b);
                assertEq(opt, ref, "mulGF256_table mismatch");
            }
        }
        // Also test zero cases
        for (uint256 x = 0; x < 256; x += 16) {
            assertEq(BinaryFieldLibOpt.mulGF256_table(x, 0), 0, "x*0 != 0");
            assertEq(BinaryFieldLibOpt.mulGF256_table(0, x), 0, "0*x != 0");
        }
    }

    // -----------------------------------------------------------------------
    //  Montgomery batch inversion correctness
    // -----------------------------------------------------------------------

    function test_batchInvert_vs_individual() public {
        uint256 n = 20;
        uint256[] memory inputs = new uint256[](n);
        uint256[] memory results = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            inputs[i] = uint256(keccak256(abi.encodePacked(i))) & ((1 << 128) - 1);
            if (i == 5) inputs[i] = 0; // test zero handling
        }

        BinaryFieldLibOpt.batchInvertGF2_128(inputs, results);

        for (uint256 i = 0; i < n; i++) {
            if (inputs[i] == 0) {
                assertEq(results[i], 0, "zero should invert to zero");
            } else {
                uint256 expected = BinaryFieldLib.invGF2_128(inputs[i]);
                assertEq(results[i], expected, "batch inv mismatch");
                // Also verify: a * inv(a) = 1
                uint256 prod = BinaryFieldLib.mulGF2_128(inputs[i], results[i]);
                assertEq(prod, 1, "a * inv(a) != 1");
            }
        }
    }

    function test_batchInvert_single_element() public {
        uint256[] memory inputs = new uint256[](1);
        uint256[] memory results = new uint256[](1);
        inputs[0] = a128;
        BinaryFieldLibOpt.batchInvertGF2_128(inputs, results);
        uint256 expected = BinaryFieldLib.invGF2_128(a128);
        assertEq(results[0], expected, "single element batch inv mismatch");
    }

    function test_bench_batchInvert_n100() public {
        uint256 n = 100;
        uint256[] memory inputs = new uint256[](n);
        uint256[] memory results = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            inputs[i] = uint256(keccak256(abi.encodePacked(i + 1))) & ((1 << 128) - 1);
        }

        uint256 g = gasleft();
        BinaryFieldLibOpt.batchInvertGF2_128(inputs, results);
        uint256 batchCost = g - gasleft();
        emit log_named_uint("[BATCH] 100 inversions via Montgomery", batchCost);
        emit log_named_uint("[BATCH] cost per element (avg)", batchCost / n);

        // Baseline: 100 individual inversions
        g = gasleft();
        for (uint256 i = 0; i < n; i++) {
            BinaryFieldLib.invGF2_128(inputs[i]);
        }
        uint256 naiveCost = g - gasleft();
        emit log_named_uint("[NAIVE] 100 inversions individually", naiveCost);
        emit log_named_uint("Speedup (naive/batch)", naiveCost / batchCost);

        assertGt(naiveCost, batchCost, "batch should be faster than naive");
    }

    // -----------------------------------------------------------------------
    //  Correctness: optimized must match reference
    // -----------------------------------------------------------------------

    function test_mul128_matches_reference() public view {
        uint256[5] memory as_ = [
            uint256(1),
            0x0123456789ABCDEF0123456789ABCDEF,
            0xFEDCBA9876543210FEDCBA9876543210,
            a128,
            b128
        ];
        uint256[5] memory bs_ = [
            uint256(1),
            0xFEDCBA9876543210FEDCBA9876543210,
            0x0123456789ABCDEF0123456789ABCDEF,
            b128,
            a128
        ];
        for (uint256 i = 0; i < 5; i++) {
            uint256 ref = BinaryFieldLib.mulGF2_128(as_[i], bs_[i]);
            uint256 opt = BinaryFieldLibOpt.mulGF2_128(as_[i], bs_[i]);
            assertEq(opt, ref, "mulGF2_128 mismatch");
        }
    }

    function test_square128_matches_reference() public view {
        uint256[4] memory xs = [
            uint256(1),
            0x0123456789ABCDEF0123456789ABCDEF,
            a128,
            b128
        ];
        for (uint256 i = 0; i < 4; i++) {
            uint256 ref = BinaryFieldLib.squareGF2_128(xs[i]);
            uint256 opt = BinaryFieldLibOpt.squareGF2_128(xs[i]);
            assertEq(opt, ref, "squareGF2_128 mismatch");
        }
    }

    function test_mul128_identity() public pure {
        uint256 a = 0x0123456789ABCDEF0123456789ABCDEF;
        assertEq(BinaryFieldLibOpt.mulGF2_128(a, 1), a, "mul by 1");
        assertEq(BinaryFieldLibOpt.mulGF2_128(a, 0), 0, "mul by 0");
    }

    function test_mul128_commutativity() public view {
        uint256 a = a128;
        uint256 b = b128;
        assertEq(
            BinaryFieldLibOpt.mulGF2_128(a, b),
            BinaryFieldLibOpt.mulGF2_128(b, a),
            "not commutative"
        );
    }

    function test_mul128_distributivity() public view {
        uint256 a = a128;
        uint256 b = b128;
        uint256 c = uint256(keccak256("c")) & ((1 << 128) - 1);
        assertEq(
            BinaryFieldLibOpt.mulGF2_128(a, b ^ c),
            BinaryFieldLibOpt.mulGF2_128(a, b) ^ BinaryFieldLibOpt.mulGF2_128(a, c),
            "distributivity failed"
        );
    }

    function test_square128_vs_mul() public view {
        uint256 a = a128;
        assertEq(
            BinaryFieldLibOpt.squareGF2_128(a),
            BinaryFieldLibOpt.mulGF2_128(a, a),
            "square != mul(a,a)"
        );
    }

    // -----------------------------------------------------------------------
    //  Input safety: upper-bits masking (security fix)
    // -----------------------------------------------------------------------

    /// @dev Verify that inputs with non-zero bits 128-255 are correctly handled.
    ///      Before the fix, shr(64, a) without masking would leak bits 128-191
    ///      into a1, producing wrong results. After the fix (a := and(a, mask128)),
    ///      both a polluted input and its masked version produce the same output.
    function test_mul128_upper_bits_ignored() public view {
        uint256 mask128 = (1 << 128) - 1;
        uint256 a = a128 | (uint256(0xDEADBEEFCAFEBABE) << 128); // bits 128+ set
        uint256 b = b128 | (uint256(0x0123456789ABCDEF) << 128);

        uint256 resultPolluted = BinaryFieldLibOpt.mulGF2_128(a, b);
        uint256 resultClean = BinaryFieldLibOpt.mulGF2_128(a & mask128, b & mask128);

        assertEq(
            resultPolluted,
            resultClean,
            "Upper bits must be masked: polluted input must give same result as clean input"
        );
    }

    function test_square128_upper_bits_ignored() public view {
        uint256 mask128 = (1 << 128) - 1;
        uint256 a = a128 | (uint256(0xDEADBEEFCAFEBABE) << 128);

        uint256 resultPolluted = BinaryFieldLibOpt.squareGF2_128(a);
        uint256 resultClean = BinaryFieldLibOpt.squareGF2_128(a & mask128);

        assertEq(
            resultPolluted,
            resultClean,
            "Upper bits must be masked in squareGF2_128"
        );
    }

    // -----------------------------------------------------------------------
    //  Fuzz tests: BinaryFieldLibOpt must equal BinaryFieldLib on all inputs
    // -----------------------------------------------------------------------

    /// @dev Foundry property test: for any 128-bit a and b,
    ///      BinaryFieldLibOpt.mulGF2_128(a, b) == BinaryFieldLib.mulGF2_128(a, b).
    ///      Run with: forge test --match-test testFuzz_mul128_matches_reference
    function testFuzz_mul128_matches_reference(uint128 aRaw, uint128 bRaw) public pure {
        uint256 a = uint256(aRaw);
        uint256 b = uint256(bRaw);
        uint256 ref = BinaryFieldLib.mulGF2_128(a, b);
        uint256 opt = BinaryFieldLibOpt.mulGF2_128(a, b);
        assertEq(opt, ref, "fuzz: mulGF2_128 opt != ref");
    }

    function testFuzz_square128_matches_reference(uint128 aRaw) public pure {
        uint256 a = uint256(aRaw);
        uint256 ref = BinaryFieldLib.squareGF2_128(a);
        uint256 opt = BinaryFieldLibOpt.squareGF2_128(a);
        assertEq(opt, ref, "fuzz: squareGF2_128 opt != ref");
    }

    // -----------------------------------------------------------------------
    //  Gas benchmarks: optimized vs reference
    // -----------------------------------------------------------------------

    function test_bench_mul128_optimized() public {
        uint256 a = a128;
        uint256 b = b128;
        uint256 g = gasleft();
        uint256 r = BinaryFieldLibOpt.mulGF2_128(a, b);
        uint256 cost = g - gasleft();
        emit log_named_uint("[OPT] mulGF2_128", cost);
        assertGt(r | 1, 0);
    }

    function test_bench_mul128_reference() public {
        uint256 a = a128;
        uint256 b = b128;
        uint256 g = gasleft();
        uint256 r = BinaryFieldLib.mulGF2_128(a, b);
        uint256 cost = g - gasleft();
        emit log_named_uint("[REF] mulGF2_128", cost);
        assertGt(r | 1, 0);
    }

    function test_bench_square128_optimized() public {
        uint256 a = a128;
        uint256 g = gasleft();
        uint256 r = BinaryFieldLibOpt.squareGF2_128(a);
        uint256 cost = g - gasleft();
        emit log_named_uint("[OPT] squareGF2_128", cost);
        assertGt(r | 1, 0);
    }

    function test_bench_square128_reference() public {
        uint256 a = a128;
        uint256 g = gasleft();
        uint256 r = BinaryFieldLib.squareGF2_128(a);
        uint256 cost = g - gasleft();
        emit log_named_uint("[REF] squareGF2_128", cost);
        assertGt(r | 1, 0);
    }
}
