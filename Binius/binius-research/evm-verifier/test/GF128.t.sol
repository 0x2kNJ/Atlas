// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/lib/GF128.sol";

/// @title GF128 unit tests — vectors from binius BinaryField128bGhash test suite
contract GF128Test is Test {
    // ─── Addition / Subtraction ──────────────────────────────────────────────

    function test_add_zero() public pure {
        assertEq(GF128.add(0, 0), 0);
    }

    function test_add_identity() public pure {
        assertEq(GF128.add(0x42, 0), 0x42);
    }

    function test_add_self_is_zero() public pure {
        uint256 a = 0xDEADBEEF;
        assertEq(GF128.add(a, a), 0, "a + a = 0 in GF(2)");
    }

    function test_sub_eq_add() public pure {
        uint256 a = 0x1234;
        uint256 b = 0x5678;
        assertEq(GF128.sub(a, b), GF128.add(a, b));
    }

    // ─── Multiplication basic ────────────────────────────────────────────────
    // Test vectors from binius `test_ghash_mul`

    function test_mul_one_one() public pure {
        assertEq(GF128.mul(1, 1), 1, "1 * 1 = 1");
    }

    function test_mul_one_two() public pure {
        assertEq(GF128.mul(1, 2), 2, "1 * 2 = 2");
    }

    function test_mul_identity() public pure {
        uint256 a = 1297182698762987;
        assertEq(GF128.mul(1, a), a, "1 * a = a");
    }

    function test_mul_two_two() public pure {
        assertEq(GF128.mul(2, 2), 4, "2 * 2 = 4 (x * x = x^2, no reduction)");
    }

    function test_mul_two_three() public pure {
        assertEq(GF128.mul(2, 3), 6, "2 * 3 = 6");
    }

    function test_mul_three_three() public pure {
        // (x+1)*(x+1) = x^2 + 1 = 5 in GF(2^128)
        assertEq(GF128.mul(3, 3), 5, "3 * 3 = 5");
    }

    function test_mul_overflow_basic() public pure {
        // x^127 * x = x^128 = x^7 + x^2 + x + 1 = 0x87
        uint256 highBit = uint256(1) << 127;
        assertEq(GF128.mul(highBit, 2), 0x87, "x^127 * x = 0x87 (reduction)");
    }

    function test_mul_overflow_plus_one() public pure {
        // (x^127 + 1) * x = x^128 + x = 0x87 ^ 2 = 0x85
        uint256 a = (uint256(1) << 127) + 1;
        assertEq(GF128.mul(a, 2), 0x85, "(x^127+1)*x = 0x85");
    }

    function test_mul_overflow_3x126() public pure {
        // 3 << 126 = x^127 + x^126
        // (x^127 + x^126) * x = x^128 + x^127 = 0x87 + (1<<127)
        uint256 a = uint256(3) << 126;
        uint256 expected = 0x87 + (uint256(1) << 127);
        assertEq(GF128.mul(a, 2), expected);
    }

    function test_mul_highbit_by_4() public pure {
        // x^127 * x^2 = x^129 = x * 0x87 = 0x87 << 1 = 0x10E
        uint256 highBit = uint256(1) << 127;
        assertEq(GF128.mul(highBit, 4), 0x87 << 1);
    }

    function test_mul_highbit_by_x122() public pure {
        // x^127 * x^122 = x^249 — requires double reduction
        // From binius: result = (0b00000111 << 121) + 0b10000111
        uint256 highBit = uint256(1) << 127;
        uint256 x122 = uint256(1) << 122;
        uint256 expected = (uint256(0x07) << 121) + 0x87;
        assertEq(GF128.mul(highBit, x122), expected);
    }

    // ─── Commutativity ───────────────────────────────────────────────────────

    function test_mul_commutative() public pure {
        uint256 a = 0xDEADBEEFCAFEBABE;
        uint256 b = 0x1234567890ABCDEF;
        assertEq(GF128.mul(a, b), GF128.mul(b, a), "mul is commutative");
    }

    // ─── Associativity ──────────────────────────────────────────────────────

    function test_mul_associative() public pure {
        uint256 a = 3;
        uint256 b = 5;
        uint256 c = 7;
        assertEq(
            GF128.mul(GF128.mul(a, b), c),
            GF128.mul(a, GF128.mul(b, c)),
            "mul is associative"
        );
    }

    // ─── Distributivity ──────────────────────────────────────────────────────

    function test_mul_distributive() public pure {
        uint256 a = 0xFF;
        uint256 b = 0xAA;
        uint256 c = 0x55;
        uint256 lhs = GF128.mul(a, GF128.add(b, c));
        uint256 rhs = GF128.add(GF128.mul(a, b), GF128.mul(a, c));
        assertEq(lhs, rhs, "a*(b+c) = a*b + a*c");
    }

    // ─── Squaring ────────────────────────────────────────────────────────────

    function test_square_basic() public pure {
        assertEq(GF128.square(0), 0, "0^2 = 0");
        assertEq(GF128.square(1), 1, "1^2 = 1");
        assertEq(GF128.square(2), 4, "x^2 = x^2");
        assertEq(GF128.square(3), 5, "(x+1)^2 = x^2+1 = 5");
    }

    function test_square_matches_mul() public pure {
        uint256 a = 0xDEADBEEFCAFEBABE;
        assertEq(GF128.square(a), GF128.mul(a, a), "square(a) = mul(a, a)");
    }

    function test_square_high_bit() public pure {
        uint256 highBit = uint256(1) << 127;
        assertEq(GF128.square(highBit), GF128.mul(highBit, highBit));
    }

    // ─── mulX ────────────────────────────────────────────────────────────────

    function test_mulX_basic() public pure {
        assertEq(GF128.mulX(1), 2, "1 * x = 2");
        assertEq(GF128.mulX(2), 4, "x * x = x^2");
    }

    function test_mulX_overflow() public pure {
        uint256 highBit = uint256(1) << 127;
        assertEq(GF128.mulX(highBit), 0x87, "x^127 * x = 0x87");
    }

    function test_mulX_matches_reference() public pure {
        uint256 a = 0x494ef99794d5244f9152df59d87a9186;
        // Reference from Rust: mul(g, 2) = 0x929df32f29aa489f22a5beb3b0f5230c
        assertEq(GF128.mulX(a), 0x929df32f29aa489f22a5beb3b0f5230c);
    }

    function test_mul_generator_by_2_reference() public pure {
        uint256 a = 0x494ef99794d5244f9152df59d87a9186;
        assertEq(GF128.mul(a, 2), 0x929df32f29aa489f22a5beb3b0f5230c, "mul(g, 2) from Rust");
    }

    function test_mul_128bit_cross_reference() public pure {
        // mul(0xdeadbeefcafebabe1234567890abcdef, 0x1234567890abcdef)
        assertEq(
            GF128.mul(0xdeadbeefcafebabe1234567890abcdef, 0x1234567890abcdef),
            0x54f61ea15dbb74cc45b24186bcc4f86f,
            "128-bit cross-reference"
        );
    }

    function test_mul_allones() public pure {
        uint256 allOnes = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        assertEq(GF128.mul(allOnes, allOnes), 0x5555555555555555555555555555402f, "all-ones squared");
    }

    function test_mul_generator_squared() public pure {
        uint256 g = 0x494ef99794d5244f9152df59d87a9186;
        assertEq(GF128.mul(g, g), 0x104e4a835b335c8b1e192ab155791f07, "g^2 from Rust");
    }

    function test_mul_large_ab() public pure {
        assertEq(
            GF128.mul(0xAAAAAAAAAAAAAAAABBBBBBBBBBBBBBBB, 0xCCCCCCCCCCCCCCCCDDDDDDDDDDDDDDDD),
            0x2c2c2c2c2c2c2c2f3b3b3b3b3b3b2536,
            "large A*B from Rust"
        );
    }

    // ─── Power ───────────────────────────────────────────────────────────────

    function test_pow_zero() public pure {
        assertEq(GF128.pow(42, 0), 1, "a^0 = 1");
    }

    function test_pow_one() public pure {
        assertEq(GF128.pow(42, 1), 42, "a^1 = a");
    }

    function test_pow_two() public pure {
        assertEq(GF128.pow(3, 2), GF128.mul(3, 3), "a^2 = a*a");
    }

    function test_pow_three() public pure {
        uint256 a = 0xFF;
        assertEq(GF128.pow(a, 3), GF128.mul(GF128.mul(a, a), a));
    }

    // ─── Zero multiplication ─────────────────────────────────────────────────

    function test_mul_by_zero() public pure {
        assertEq(GF128.mul(0, 42), 0, "0 * a = 0");
        assertEq(GF128.mul(42, 0), 0, "a * 0 = 0");
    }

    // ─── Large value test ────────────────────────────────────────────────────

    function test_mul_large_values() public pure {
        // Use the MULTIPLICATIVE_GENERATOR from binius
        uint256 g = 0x494ef99794d5244f9152df59d87a9186;
        uint256 g2 = GF128.mul(g, g);
        uint256 g3 = GF128.mul(g2, g);
        // g^3 = g^2 * g; verify associativity holds for large values
        assertEq(g3, GF128.mul(g, g2), "g^3 via both orderings");
    }

    // ─── Benchmark: mul gas cost ─────────────────────────────────────────────

    function test_bench_mul() public {
        uint256 a = 0x494ef99794d5244f9152df59d87a9186;
        uint256 b = 0xDEADBEEFCAFEBABE1234567890ABCDEF;
        uint256 g0 = gasleft();
        GF128.mul(a, b);
        uint256 g1 = gasleft();
        uint256 gasUsed = g0 - g1;
        emit log_named_uint("GF128.mul gas", gasUsed);
    }

    function test_bench_square() public {
        uint256 a = 0x494ef99794d5244f9152df59d87a9186;
        uint256 g0 = gasleft();
        GF128.square(a);
        uint256 g1 = gasleft();
        uint256 gasUsed = g0 - g1;
        emit log_named_uint("GF128.square gas", gasUsed);
    }
}
