// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/BinaryFieldLib.sol";

contract BinaryFieldLibTest is Test {
    using BinaryFieldLib for uint256;

    // -----------------------------------------------------------------------
    //  GF(2^2) tests
    // -----------------------------------------------------------------------

    function test_GF4_mul_identity() public pure {
        for (uint256 a = 0; a < 4; a++) {
            assertEq(BinaryFieldLib.mulGF4(a, 1), a, "mul by 1 should be identity");
            assertEq(BinaryFieldLib.mulGF4(a, 0), 0, "mul by 0 should be 0");
        }
    }

    function test_GF4_mul_commutativity() public pure {
        for (uint256 a = 0; a < 4; a++) {
            for (uint256 b = 0; b < 4; b++) {
                assertEq(
                    BinaryFieldLib.mulGF4(a, b),
                    BinaryFieldLib.mulGF4(b, a),
                    "GF4 mul not commutative"
                );
            }
        }
    }

    function test_GF4_mul_associativity() public pure {
        for (uint256 a = 0; a < 4; a++) {
            for (uint256 b = 0; b < 4; b++) {
                for (uint256 c = 0; c < 4; c++) {
                    assertEq(
                        BinaryFieldLib.mulGF4(BinaryFieldLib.mulGF4(a, b), c),
                        BinaryFieldLib.mulGF4(a, BinaryFieldLib.mulGF4(b, c)),
                        "GF4 mul not associative"
                    );
                }
            }
        }
    }

    function test_GF4_inverse() public pure {
        for (uint256 a = 1; a < 4; a++) {
            uint256 inv = BinaryFieldLib.invGF4(a);
            assertEq(BinaryFieldLib.mulGF4(a, inv), 1, "GF4 inverse failed");
        }
    }

    function test_GF4_known_values() public pure {
        // α * α = α + 1  (where α = 0b10 = 2)
        // 2 * 2 should give 3
        assertEq(BinaryFieldLib.mulGF4(2, 2), 3);
        // (α+1) * (α+1) = α^2 + 1 = (α+1) + 1 = α = 2
        assertEq(BinaryFieldLib.mulGF4(3, 3), 2);
        // α * (α+1) = α^2 + α = (α+1) + α = 1
        assertEq(BinaryFieldLib.mulGF4(2, 3), 1);
    }

    // -----------------------------------------------------------------------
    //  GF(2^4) tests
    // -----------------------------------------------------------------------

    function test_GF16_mul_identity() public pure {
        for (uint256 a = 0; a < 16; a++) {
            assertEq(BinaryFieldLib.mulGF16(a, 1), a, "GF16 mul by 1");
            assertEq(BinaryFieldLib.mulGF16(a, 0), 0, "GF16 mul by 0");
        }
    }

    function test_GF16_mul_commutativity() public pure {
        for (uint256 a = 0; a < 16; a++) {
            for (uint256 b = 0; b < 16; b++) {
                assertEq(
                    BinaryFieldLib.mulGF16(a, b),
                    BinaryFieldLib.mulGF16(b, a),
                    "GF16 mul not commutative"
                );
            }
        }
    }

    function test_GF16_inverse() public pure {
        for (uint256 a = 1; a < 16; a++) {
            uint256 inv = BinaryFieldLib.invGF16(a);
            assertEq(BinaryFieldLib.mulGF16(a, inv), 1, "GF16 inverse failed");
        }
    }

    function test_GF16_square_vs_mul() public pure {
        for (uint256 a = 0; a < 16; a++) {
            assertEq(
                BinaryFieldLib.squareGF16(a),
                BinaryFieldLib.mulGF16(a, a),
                "GF16 square != mul(a,a)"
            );
        }
    }

    function test_GF16_fermat() public pure {
        // a^{15} = 1 for all a != 0 in GF(2^4) (Fermat's little theorem)
        for (uint256 a = 1; a < 16; a++) {
            uint256 r = a;
            for (uint256 i = 1; i < 15; i++) {
                r = BinaryFieldLib.mulGF16(r, a);
            }
            assertEq(r, 1, "GF16 Fermat failed");
        }
    }

    // -----------------------------------------------------------------------
    //  GF(2^8) tests
    // -----------------------------------------------------------------------

    function test_GF256_mul_identity() public pure {
        for (uint256 a = 0; a < 256; a++) {
            assertEq(BinaryFieldLib.mulGF256(a, 1), a, "GF256 mul by 1");
            assertEq(BinaryFieldLib.mulGF256(a, 0), 0, "GF256 mul by 0");
        }
    }

    function test_GF256_mul_commutativity_sampled() public pure {
        uint256[8] memory samples = [uint256(0), 1, 2, 15, 42, 127, 200, 255];
        for (uint256 i = 0; i < 8; i++) {
            for (uint256 j = 0; j < 8; j++) {
                assertEq(
                    BinaryFieldLib.mulGF256(samples[i], samples[j]),
                    BinaryFieldLib.mulGF256(samples[j], samples[i]),
                    "GF256 mul not commutative"
                );
            }
        }
    }

    function test_GF256_square_vs_mul() public pure {
        for (uint256 a = 0; a < 256; a++) {
            assertEq(
                BinaryFieldLib.squareGF256(a),
                BinaryFieldLib.mulGF256(a, a),
                "GF256 square != mul(a,a)"
            );
        }
    }

    function test_GF256_inverse_exhaustive() public pure {
        for (uint256 a = 1; a < 256; a++) {
            uint256 inv = BinaryFieldLib.invGF256(a);
            assertEq(BinaryFieldLib.mulGF256(a, inv), 1, "GF256 inverse failed");
        }
    }

    function test_GF256_fermat() public pure {
        // a^255 = 1 for all nonzero a
        uint256[5] memory samples = [uint256(1), 2, 42, 127, 255];
        for (uint256 i = 0; i < 5; i++) {
            uint256 a = samples[i];
            uint256 r = a;
            for (uint256 j = 1; j < 255; j++) {
                r = BinaryFieldLib.mulGF256(r, a);
            }
            assertEq(r, 1, "GF256 Fermat failed");
        }
    }

    // -----------------------------------------------------------------------
    //  GF(2^16) tests
    // -----------------------------------------------------------------------

    function test_GF65536_mul_identity() public pure {
        uint256[6] memory samples = [uint256(0), 1, 2, 0xFF, 0x1234, 0xFFFF];
        for (uint256 i = 0; i < 6; i++) {
            assertEq(BinaryFieldLib.mulGF65536(samples[i], 1), samples[i], "GF65536 mul by 1");
            assertEq(BinaryFieldLib.mulGF65536(samples[i], 0), 0, "GF65536 mul by 0");
        }
    }

    function test_GF65536_square_vs_mul() public pure {
        uint256[6] memory samples = [uint256(0), 1, 0x42, 0xFF, 0x1234, 0xFFFF];
        for (uint256 i = 0; i < 6; i++) {
            assertEq(
                BinaryFieldLib.squareGF65536(samples[i]),
                BinaryFieldLib.mulGF65536(samples[i], samples[i]),
                "GF65536 square != mul(a,a)"
            );
        }
    }

    function test_GF65536_commutativity() public pure {
        uint256[6] memory samples = [uint256(0), 1, 0x42, 0xFF, 0x1234, 0xFFFF];
        for (uint256 i = 0; i < 6; i++) {
            for (uint256 j = 0; j < 6; j++) {
                assertEq(
                    BinaryFieldLib.mulGF65536(samples[i], samples[j]),
                    BinaryFieldLib.mulGF65536(samples[j], samples[i]),
                    "GF65536 mul not commutative"
                );
            }
        }
    }

    // -----------------------------------------------------------------------
    //  GF(2^32) tests
    // -----------------------------------------------------------------------

    function test_GF2_32_mul_identity() public pure {
        uint256[5] memory samples = [uint256(0), 1, 0xDEAD, 0x12345678, 0xFFFFFFFF];
        for (uint256 i = 0; i < 5; i++) {
            assertEq(BinaryFieldLib.mulGF2_32(samples[i], 1), samples[i], "GF2_32 mul by 1");
            assertEq(BinaryFieldLib.mulGF2_32(samples[i], 0), 0, "GF2_32 mul by 0");
        }
    }

    function test_GF2_32_square_vs_mul() public pure {
        uint256[5] memory samples = [uint256(0), 1, 0xDEAD, 0x12345678, 0xFFFFFFFF];
        for (uint256 i = 0; i < 5; i++) {
            assertEq(
                BinaryFieldLib.squareGF2_32(samples[i]),
                BinaryFieldLib.mulGF2_32(samples[i], samples[i]),
                "GF2_32 square != mul"
            );
        }
    }

    // -----------------------------------------------------------------------
    //  GF(2^64) tests — the Binius64 native field
    // -----------------------------------------------------------------------

    function test_GF2_64_mul_identity() public pure {
        uint256[5] memory samples = [
            uint256(0),
            1,
            0xDEADBEEF,
            0x123456789ABCDEF0,
            0xFFFFFFFFFFFFFFFF
        ];
        for (uint256 i = 0; i < 5; i++) {
            assertEq(BinaryFieldLib.mulGF2_64(samples[i], 1), samples[i], "GF2_64 mul by 1");
            assertEq(BinaryFieldLib.mulGF2_64(samples[i], 0), 0, "GF2_64 mul by 0");
        }
    }

    function test_GF2_64_commutativity() public pure {
        uint256[5] memory samples = [
            uint256(0),
            1,
            0xDEADBEEF,
            0x123456789ABCDEF0,
            0xFFFFFFFFFFFFFFFF
        ];
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = 0; j < 5; j++) {
                assertEq(
                    BinaryFieldLib.mulGF2_64(samples[i], samples[j]),
                    BinaryFieldLib.mulGF2_64(samples[j], samples[i]),
                    "GF2_64 not commutative"
                );
            }
        }
    }

    function test_GF2_64_square_vs_mul() public pure {
        uint256[4] memory samples = [
            uint256(1),
            0xDEADBEEF,
            0x123456789ABCDEF0,
            0xFFFFFFFFFFFFFFFF
        ];
        for (uint256 i = 0; i < 4; i++) {
            assertEq(
                BinaryFieldLib.squareGF2_64(samples[i]),
                BinaryFieldLib.mulGF2_64(samples[i], samples[i]),
                "GF2_64 square != mul"
            );
        }
    }

    function test_GF2_64_inverse() public pure {
        uint256[4] memory samples = [
            uint256(1),
            0xDEADBEEF,
            0x123456789ABCDEF0,
            0xFFFFFFFFFFFFFFFF
        ];
        for (uint256 i = 0; i < 4; i++) {
            uint256 a = samples[i];
            uint256 inv = BinaryFieldLib.invGF2_64(a);
            assertEq(BinaryFieldLib.mulGF2_64(a, inv), 1, "GF2_64 inverse failed");
        }
    }

    function test_GF2_64_distributivity() public pure {
        uint256 a = 0x123456789ABCDEF0;
        uint256 b = 0xFEDCBA9876543210;
        uint256 c = 0xDEADBEEFCAFEBABE;
        // a * (b + c) = a*b + a*c  (where + is XOR)
        uint256 lhs = BinaryFieldLib.mulGF2_64(a, b ^ c);
        uint256 rhs = BinaryFieldLib.mulGF2_64(a, b) ^ BinaryFieldLib.mulGF2_64(a, c);
        assertEq(lhs, rhs, "GF2_64 distributivity failed");
    }

    // -----------------------------------------------------------------------
    //  GF(2^128) tests — the cryptographic extension field
    // -----------------------------------------------------------------------

    function test_GF2_128_mul_identity() public pure {
        uint256 a = 0x0123456789ABCDEF0123456789ABCDEF;
        assertEq(BinaryFieldLib.mulGF2_128(a, 1), a, "GF2_128 mul by 1");
        assertEq(BinaryFieldLib.mulGF2_128(a, 0), 0, "GF2_128 mul by 0");
    }

    function test_GF2_128_commutativity() public pure {
        uint256 a = 0x0123456789ABCDEF0123456789ABCDEF;
        uint256 b = 0xFEDCBA9876543210FEDCBA9876543210;
        assertEq(
            BinaryFieldLib.mulGF2_128(a, b),
            BinaryFieldLib.mulGF2_128(b, a),
            "GF2_128 not commutative"
        );
    }

    function test_GF2_128_square_vs_mul() public pure {
        uint256 a = 0xDEADBEEFCAFEBABE1234567890ABCDEF;
        assertEq(
            BinaryFieldLib.squareGF2_128(a),
            BinaryFieldLib.mulGF2_128(a, a),
            "GF2_128 square != mul"
        );
    }

    function test_GF2_128_inverse() public pure {
        uint256[3] memory samples = [
            uint256(1),
            0xDEADBEEFCAFEBABE1234567890ABCDEF,
            0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
        ];
        for (uint256 i = 0; i < 3; i++) {
            uint256 a = samples[i];
            uint256 inv = BinaryFieldLib.invGF2_128(a);
            assertEq(BinaryFieldLib.mulGF2_128(a, inv), 1, "GF2_128 inverse failed");
        }
    }

    function test_GF2_128_distributivity() public pure {
        uint256 a = 0x0123456789ABCDEF0123456789ABCDEF;
        uint256 b = 0xFEDCBA9876543210FEDCBA9876543210;
        uint256 c = 0xDEADBEEFCAFEBABEDEADBEEFCAFEBABE;
        uint256 lhs = BinaryFieldLib.mulGF2_128(a, b ^ c);
        uint256 rhs = BinaryFieldLib.mulGF2_128(a, b) ^ BinaryFieldLib.mulGF2_128(a, c);
        assertEq(lhs, rhs, "GF2_128 distributivity failed");
    }

    // -----------------------------------------------------------------------
    //  eqEval tests
    // -----------------------------------------------------------------------

    function test_eqEval_same_point() public pure {
        uint256[] memory r = new uint256[](2);
        r[0] = 0x0A;
        r[1] = 0x0B;
        uint256 result = BinaryFieldLib.eqEval(r, r);
        // eq(r, r) = 1 for any r (each term = r_i^2 + (1+r_i)^2)
        // In binary field: r_i^2 + (1 XOR r_i)^2
        // This equals 1 only when r_i ∈ {0,1}. For general field elements, not necessarily 1.
        // Actually eq(r,r) = prod_i(r_i * r_i + (1+r_i)*(1+r_i)) = prod_i(r_i^2 + 1 + r_i + r_i + r_i^2) = prod_i(1) = 1 in char 2
        // Wait: in char 2, 2*r_i = 0, so (1+r_i)*(1+r_i) = 1 + r_i + r_i + r_i^2 = 1 + r_i^2.
        // So term = r_i^2 + 1 + r_i^2 = 1. Yes, eq(r,r) = 1 always.
        assertEq(result, 1, "eqEval(r,r) should be 1");
    }

    function test_eqEval_boolean_points() public pure {
        // For boolean inputs {0,1}, eq(r,x) = 1 iff r == x, else 0.
        uint256[] memory r = new uint256[](2);
        uint256[] memory x = new uint256[](2);
        r[0] = 1;
        r[1] = 0;
        x[0] = 1;
        x[1] = 0;
        assertEq(BinaryFieldLib.eqEval(r, x), 1, "eq same boolean should be 1");

        x[1] = 1;
        assertEq(BinaryFieldLib.eqEval(r, x), 0, "eq diff boolean should be 0");
    }

    // -----------------------------------------------------------------------
    //  Gas benchmarks
    // -----------------------------------------------------------------------

    function test_gas_mulGF4() public {
        uint256 a = 3;
        uint256 b = 2;
        uint256 g = gasleft();
        BinaryFieldLib.mulGF4(a, b);
        uint256 cost = g - gasleft();
        emit log_named_uint("Gas: mulGF4", cost);
    }

    function test_gas_mulGF16() public {
        uint256 a = 0xF;
        uint256 b = 0xA;
        uint256 g = gasleft();
        BinaryFieldLib.mulGF16(a, b);
        uint256 cost = g - gasleft();
        emit log_named_uint("Gas: mulGF16", cost);
    }

    function test_gas_mulGF256() public {
        uint256 a = 0xFF;
        uint256 b = 0xAB;
        uint256 g = gasleft();
        BinaryFieldLib.mulGF256(a, b);
        uint256 cost = g - gasleft();
        emit log_named_uint("Gas: mulGF256", cost);
    }

    function test_gas_mulGF65536() public {
        uint256 a = 0xFFFF;
        uint256 b = 0xABCD;
        uint256 g = gasleft();
        BinaryFieldLib.mulGF65536(a, b);
        uint256 cost = g - gasleft();
        emit log_named_uint("Gas: mulGF65536", cost);
    }

    function test_gas_mulGF2_32() public {
        uint256 a = 0xFFFFFFFF;
        uint256 b = 0xABCDEF01;
        uint256 g = gasleft();
        BinaryFieldLib.mulGF2_32(a, b);
        uint256 cost = g - gasleft();
        emit log_named_uint("Gas: mulGF2_32", cost);
    }

    function test_gas_mulGF2_64() public {
        uint256 a = 0xFFFFFFFFFFFFFFFF;
        uint256 b = 0xABCDEF0123456789;
        uint256 g = gasleft();
        BinaryFieldLib.mulGF2_64(a, b);
        uint256 cost = g - gasleft();
        emit log_named_uint("Gas: mulGF2_64", cost);
    }

    function test_gas_squareGF2_64() public {
        uint256 a = 0xFFFFFFFFFFFFFFFF;
        uint256 g = gasleft();
        BinaryFieldLib.squareGF2_64(a);
        uint256 cost = g - gasleft();
        emit log_named_uint("Gas: squareGF2_64", cost);
    }

    function test_gas_invGF2_64() public {
        uint256 a = 0x123456789ABCDEF0;
        uint256 g = gasleft();
        BinaryFieldLib.invGF2_64(a);
        uint256 cost = g - gasleft();
        emit log_named_uint("Gas: invGF2_64", cost);
    }

    function test_gas_mulGF2_128() public {
        uint256 a = 0x0123456789ABCDEF0123456789ABCDEF;
        uint256 b = 0xFEDCBA9876543210FEDCBA9876543210;
        uint256 g = gasleft();
        BinaryFieldLib.mulGF2_128(a, b);
        uint256 cost = g - gasleft();
        emit log_named_uint("Gas: mulGF2_128", cost);
    }

    function test_gas_squareGF2_128() public {
        uint256 a = 0x0123456789ABCDEF0123456789ABCDEF;
        uint256 g = gasleft();
        BinaryFieldLib.squareGF2_128(a);
        uint256 cost = g - gasleft();
        emit log_named_uint("Gas: squareGF2_128", cost);
    }

    function test_gas_invGF2_128() public {
        uint256 a = 0x0123456789ABCDEF0123456789ABCDEF;
        uint256 g = gasleft();
        BinaryFieldLib.invGF2_128(a);
        uint256 cost = g - gasleft();
        emit log_named_uint("Gas: invGF2_128", cost);
    }
}
