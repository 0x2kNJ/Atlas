// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

/// @title BinaryFieldLib
/// @notice Arithmetic over the canonical Binius tower of binary fields.
///
///   Tower construction (matches binius64 crate):
///     T_0 = GF(2)
///     T_{k+1} = T_k[β_k] / (β_k² + β_{k-1}·β_k + 1)
///
///   At each level, an element of T_{k+1} is (hi, lo) where hi, lo ∈ T_k.
///   Packed into a uint256 with lo in the lower bits.
///
///   Key operations at each level:
///     mulAlpha_k: multiply by the level-k generator β_k.
///       mulAlpha_0(x) = x  (GF(2) base case: β₀ is the identity element 1,
///                           so multiplying by β₀ = 1 is the identity map)
///       mulAlpha_1(a1, a0) = (a1, a0 ⊕ mulAlpha_0(a1)) = (a1, a0 ⊕ a1)
///       mulAlpha_k(a0, a1) = (a1, a0 ⊕ mulAlpha_{k-1}(a1))  for k ≥ 2
///
///     multiply: Karatsuba with the reduction β_k² = β_{k-1}·β_k + 1:
///       lo = p0 ⊕ p1
///       hi = (pm ⊕ p0 ⊕ p1) ⊕ mulAlpha_{k-1}(p1)
///
///     square:
///       lo = sq(a0) ⊕ sq(a1)
///       hi = mulAlpha_{k-1}(sq(a1))
library BinaryFieldLib {
    // -----------------------------------------------------------------------
    //  GF(2^2) — Level 1.  β₁² + 1·β₁ + 1 = 0 (since β₀ acts as identity)
    //  Elements: {0, 1, β₁, β₁+1} encoded as {0, 1, 2, 3}
    // -----------------------------------------------------------------------

    /// @notice Multiply two GF(2^2) elements.
    function mulGF4(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 a0 = a & 1;
        uint256 a1 = (a >> 1) & 1;
        uint256 b0 = b & 1;
        uint256 b1 = (b >> 1) & 1;

        uint256 p0 = a0 & b0;
        uint256 p1 = a1 & b1;
        uint256 pm = (a0 ^ a1) & (b0 ^ b1);

        // mulAlpha_0(p1) = p1 (identity at level 0)
        uint256 lo = p0 ^ p1;
        uint256 hi = (pm ^ p0 ^ p1) ^ p1; // = pm ^ p0

        return lo | (hi << 1);
    }

    function squareGF4(uint256 a) internal pure returns (uint256) {
        uint256 a0 = a & 1;
        uint256 a1 = (a >> 1) & 1;
        // In GF(2), squaring is identity
        uint256 lo = a0 ^ a1;
        // mulAlpha_0(a1²) = a1
        uint256 hi = a1;
        return lo | (hi << 1);
    }

    /// @notice mulAlpha at level 1: multiply by β₁ in GF(2²).
    ///   β₁·(a1·β₁ + a0) = a1·β₁² + a0·β₁ = a1·(β₁+1) + a0·β₁ = (a0+a1)·β₁ + a1
    function mulAlphaGF4(uint256 a) internal pure returns (uint256) {
        uint256 a0 = a & 1;
        uint256 a1 = (a >> 1) & 1;
        // result: lo = a1, hi = a0 + mulAlpha_0(a1) = a0 + a1
        return a1 | ((a0 ^ a1) << 1);
    }

    function invGF4(uint256 a) internal pure returns (uint256) {
        // Only 4 elements: inv(1)=1, inv(2)=3, inv(3)=2
        if (a <= 1) return a;
        return a ^ 1;
    }

    // -----------------------------------------------------------------------
    //  GF(2^4) — Level 2.  β₂² + β₁·β₂ + 1 = 0
    //  Element: a1·β₂ + a0, where a0, a1 ∈ GF(2²)
    // -----------------------------------------------------------------------

    function mulGF16(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 a0 = a & 0x3;
        uint256 a1 = (a >> 2) & 0x3;
        uint256 b0 = b & 0x3;
        uint256 b1 = (b >> 2) & 0x3;

        uint256 p0 = mulGF4(a0, b0);
        uint256 p1 = mulGF4(a1, b1);
        uint256 pm = mulGF4(a0 ^ a1, b0 ^ b1);

        uint256 lo = p0 ^ p1;
        uint256 hi = (pm ^ p0 ^ p1) ^ mulAlphaGF4(p1);

        return lo | (hi << 2);
    }

    function squareGF16(uint256 a) internal pure returns (uint256) {
        uint256 a0 = a & 0x3;
        uint256 a1 = (a >> 2) & 0x3;
        uint256 sq0 = squareGF4(a0);
        uint256 sq1 = squareGF4(a1);
        uint256 lo = sq0 ^ sq1;
        uint256 hi = mulAlphaGF4(sq1);
        return lo | (hi << 2);
    }

    /// @notice mulAlpha at level 2: multiply by β₂ in GF(2⁴).
    function mulAlphaGF16(uint256 a) internal pure returns (uint256) {
        uint256 a0 = a & 0x3;
        uint256 a1 = (a >> 2) & 0x3;
        uint256 lo = a1;
        uint256 hi = a0 ^ mulAlphaGF4(a1);
        return lo | (hi << 2);
    }

    function invGF16(uint256 a) internal pure returns (uint256) {
        if (a == 0) return 0;
        // a^{-1} = a^{14} = (a^7)^2 in GF(2^4)
        uint256 a2 = squareGF16(a);
        uint256 a3 = mulGF16(a2, a);
        uint256 a6 = squareGF16(a3);
        uint256 a7 = mulGF16(a6, a);
        return squareGF16(a7);
    }

    // -----------------------------------------------------------------------
    //  GF(2^8) — Level 3.  β₃² + β₂·β₃ + 1 = 0
    // -----------------------------------------------------------------------

    function mulGF256(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 a0 = a & 0xF;
        uint256 a1 = (a >> 4) & 0xF;
        uint256 b0 = b & 0xF;
        uint256 b1 = (b >> 4) & 0xF;

        uint256 p0 = mulGF16(a0, b0);
        uint256 p1 = mulGF16(a1, b1);
        uint256 pm = mulGF16(a0 ^ a1, b0 ^ b1);

        uint256 lo = p0 ^ p1;
        uint256 hi = (pm ^ p0 ^ p1) ^ mulAlphaGF16(p1);

        return lo | (hi << 4);
    }

    function squareGF256(uint256 a) internal pure returns (uint256) {
        uint256 a0 = a & 0xF;
        uint256 a1 = (a >> 4) & 0xF;
        uint256 sq0 = squareGF16(a0);
        uint256 sq1 = squareGF16(a1);
        uint256 lo = sq0 ^ sq1;
        uint256 hi = mulAlphaGF16(sq1);
        return lo | (hi << 4);
    }

    function mulAlphaGF256(uint256 a) internal pure returns (uint256) {
        uint256 a0 = a & 0xF;
        uint256 a1 = (a >> 4) & 0xF;
        uint256 lo = a1;
        uint256 hi = a0 ^ mulAlphaGF16(a1);
        return lo | (hi << 4);
    }

    function invGF256(uint256 a) internal pure returns (uint256) {
        if (a == 0) return 0;
        // Itoh-Tsujii: a^{-1} = (a^{2^7-1})^2 = (a^127)^2
        uint256 r2 = mulGF256(squareGF256(a), a);          // a^{2^2-1}
        uint256 r4 = mulGF256(_squareN_256(r2, 2), r2);    // a^{2^4-1}
        uint256 r3 = mulGF256(_squareN_256(r2, 1), a);     // a^{2^3-1}
        uint256 r7 = mulGF256(_squareN_256(r4, 3), r3);    // a^{2^7-1}
        return squareGF256(r7);
    }

    function _squareN_256(uint256 a, uint256 n) private pure returns (uint256) {
        for (uint256 i = 0; i < n; i++) {
            a = squareGF256(a);
        }
        return a;
    }

    // -----------------------------------------------------------------------
    //  GF(2^16) — Level 4.  β₄² + β₃·β₄ + 1 = 0
    // -----------------------------------------------------------------------

    function mulGF65536(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 a0 = a & 0xFF;
        uint256 a1 = (a >> 8) & 0xFF;
        uint256 b0 = b & 0xFF;
        uint256 b1 = (b >> 8) & 0xFF;

        uint256 p0 = mulGF256(a0, b0);
        uint256 p1 = mulGF256(a1, b1);
        uint256 pm = mulGF256(a0 ^ a1, b0 ^ b1);

        uint256 lo = p0 ^ p1;
        uint256 hi = (pm ^ p0 ^ p1) ^ mulAlphaGF256(p1);

        return lo | (hi << 8);
    }

    function squareGF65536(uint256 a) internal pure returns (uint256) {
        uint256 a0 = a & 0xFF;
        uint256 a1 = (a >> 8) & 0xFF;
        uint256 sq0 = squareGF256(a0);
        uint256 sq1 = squareGF256(a1);
        uint256 lo = sq0 ^ sq1;
        uint256 hi = mulAlphaGF256(sq1);
        return lo | (hi << 8);
    }

    function mulAlphaGF65536(uint256 a) internal pure returns (uint256) {
        uint256 a0 = a & 0xFF;
        uint256 a1 = (a >> 8) & 0xFF;
        uint256 lo = a1;
        uint256 hi = a0 ^ mulAlphaGF256(a1);
        return lo | (hi << 8);
    }

    // -----------------------------------------------------------------------
    //  GF(2^32) — Level 5
    // -----------------------------------------------------------------------

    function mulGF2_32(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 a0 = a & 0xFFFF;
        uint256 a1 = (a >> 16) & 0xFFFF;
        uint256 b0 = b & 0xFFFF;
        uint256 b1 = (b >> 16) & 0xFFFF;

        uint256 p0 = mulGF65536(a0, b0);
        uint256 p1 = mulGF65536(a1, b1);
        uint256 pm = mulGF65536(a0 ^ a1, b0 ^ b1);

        uint256 lo = p0 ^ p1;
        uint256 hi = (pm ^ p0 ^ p1) ^ mulAlphaGF65536(p1);

        return lo | (hi << 16);
    }

    function squareGF2_32(uint256 a) internal pure returns (uint256) {
        uint256 a0 = a & 0xFFFF;
        uint256 a1 = (a >> 16) & 0xFFFF;
        uint256 sq0 = squareGF65536(a0);
        uint256 sq1 = squareGF65536(a1);
        uint256 lo = sq0 ^ sq1;
        uint256 hi = mulAlphaGF65536(sq1);
        return lo | (hi << 16);
    }

    function mulAlphaGF2_32(uint256 a) internal pure returns (uint256) {
        uint256 a0 = a & 0xFFFF;
        uint256 a1 = (a >> 16) & 0xFFFF;
        uint256 lo = a1;
        uint256 hi = a0 ^ mulAlphaGF65536(a1);
        return lo | (hi << 16);
    }

    // -----------------------------------------------------------------------
    //  GF(2^64) — Level 6.  The native Binius64 word field.
    // -----------------------------------------------------------------------

    function mulGF2_64(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 a0 = a & 0xFFFFFFFF;
        uint256 a1 = (a >> 32) & 0xFFFFFFFF;
        uint256 b0 = b & 0xFFFFFFFF;
        uint256 b1 = (b >> 32) & 0xFFFFFFFF;

        uint256 p0 = mulGF2_32(a0, b0);
        uint256 p1 = mulGF2_32(a1, b1);
        uint256 pm = mulGF2_32(a0 ^ a1, b0 ^ b1);

        uint256 lo = p0 ^ p1;
        uint256 hi = (pm ^ p0 ^ p1) ^ mulAlphaGF2_32(p1);

        return lo | (hi << 32);
    }

    function squareGF2_64(uint256 a) internal pure returns (uint256) {
        uint256 a0 = a & 0xFFFFFFFF;
        uint256 a1 = (a >> 32) & 0xFFFFFFFF;
        uint256 sq0 = squareGF2_32(a0);
        uint256 sq1 = squareGF2_32(a1);
        uint256 lo = sq0 ^ sq1;
        uint256 hi = mulAlphaGF2_32(sq1);
        return lo | (hi << 32);
    }

    function mulAlphaGF2_64(uint256 a) internal pure returns (uint256) {
        uint256 a0 = a & 0xFFFFFFFF;
        uint256 a1 = (a >> 32) & 0xFFFFFFFF;
        uint256 lo = a1;
        uint256 hi = a0 ^ mulAlphaGF2_32(a1);
        return lo | (hi << 32);
    }

    function invGF2_64(uint256 a) internal pure returns (uint256) {
        if (a == 0) return 0;
        return _invGF2_64_inner(a);
    }

    function _invGF2_64_inner(uint256 a) private pure returns (uint256) {
        // a^{-1} = (a^{2^63-1})^2
        uint256 r2 = mulGF2_64(_squareN_64(a, 1), a);
        uint256 r4 = mulGF2_64(_squareN_64(r2, 2), r2);
        uint256 r8 = mulGF2_64(_squareN_64(r4, 4), r4);
        uint256 r16 = mulGF2_64(_squareN_64(r8, 8), r8);
        uint256 r32 = mulGF2_64(_squareN_64(r16, 16), r16);
        uint256 r3 = mulGF2_64(_squareN_64(r2, 1), a);
        uint256 r7 = mulGF2_64(_squareN_64(r4, 3), r3);
        uint256 r15 = mulGF2_64(_squareN_64(r8, 7), r7);
        uint256 r31 = mulGF2_64(_squareN_64(r16, 15), r15);
        uint256 r63 = mulGF2_64(_squareN_64(r32, 31), r31);
        return squareGF2_64(r63);
    }

    function _squareN_64(uint256 a, uint256 n) internal pure returns (uint256) {
        for (uint256 i = 0; i < n; i++) {
            a = squareGF2_64(a);
        }
        return a;
    }

    // -----------------------------------------------------------------------
    //  GF(2^128) — Level 7.  The cryptographic extension field.
    // -----------------------------------------------------------------------

    function mulGF2_128(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 a0 = a & 0xFFFFFFFFFFFFFFFF;
        uint256 a1 = (a >> 64) & 0xFFFFFFFFFFFFFFFF;
        uint256 b0 = b & 0xFFFFFFFFFFFFFFFF;
        uint256 b1 = (b >> 64) & 0xFFFFFFFFFFFFFFFF;

        uint256 p0 = mulGF2_64(a0, b0);
        uint256 p1 = mulGF2_64(a1, b1);
        uint256 pm = mulGF2_64(a0 ^ a1, b0 ^ b1);

        uint256 lo = p0 ^ p1;
        uint256 hi = (pm ^ p0 ^ p1) ^ mulAlphaGF2_64(p1);

        return lo | (hi << 64);
    }

    function squareGF2_128(uint256 a) internal pure returns (uint256) {
        uint256 a0 = a & 0xFFFFFFFFFFFFFFFF;
        uint256 a1 = (a >> 64) & 0xFFFFFFFFFFFFFFFF;
        uint256 sq0 = squareGF2_64(a0);
        uint256 sq1 = squareGF2_64(a1);
        uint256 lo = sq0 ^ sq1;
        uint256 hi = mulAlphaGF2_64(sq1);
        return lo | (hi << 64);
    }

    function invGF2_128(uint256 a) internal pure returns (uint256) {
        if (a == 0) return 0;
        return _invGF2_128_inner(a);
    }

    function _invGF2_128_inner(uint256 a) private pure returns (uint256) {
        // a^{-1} = (a^{2^127-1})^2
        uint256 r2 = mulGF2_128(_squareN_128(a, 1), a);
        uint256 r4 = mulGF2_128(_squareN_128(r2, 2), r2);
        uint256 r8 = mulGF2_128(_squareN_128(r4, 4), r4);
        uint256 r16 = mulGF2_128(_squareN_128(r8, 8), r8);
        uint256 r32 = mulGF2_128(_squareN_128(r16, 16), r16);
        uint256 r64 = mulGF2_128(_squareN_128(r32, 32), r32);
        uint256 r3 = mulGF2_128(_squareN_128(r2, 1), a);
        uint256 r7 = mulGF2_128(_squareN_128(r4, 3), r3);
        uint256 r15 = mulGF2_128(_squareN_128(r8, 7), r7);
        uint256 r31 = mulGF2_128(_squareN_128(r16, 15), r15);
        uint256 r63 = mulGF2_128(_squareN_128(r32, 31), r31);
        uint256 r127 = mulGF2_128(_squareN_128(r64, 63), r63);
        return squareGF2_128(r127);
    }

    function _squareN_128(uint256 a, uint256 n) internal pure returns (uint256) {
        for (uint256 i = 0; i < n; i++) {
            a = squareGF2_128(a);
        }
        return a;
    }

    // -----------------------------------------------------------------------
    //  Multilinear evaluation helper: eq(r, x)
    // -----------------------------------------------------------------------

    function eqEval(uint256[] memory r, uint256[] memory x) internal pure returns (uint256) {
        require(r.length == x.length, "eqEval: length mismatch");
        uint256 result = 1;
        for (uint256 i = 0; i < r.length; i++) {
            uint256 ri = r[i];
            uint256 xi = x[i];
            uint256 prod = mulGF2_128(ri, xi);
            uint256 compProd = mulGF2_128(ri ^ 1, xi ^ 1);
            uint256 term = prod ^ compProd;
            result = mulGF2_128(result, term);
        }
        return result;
    }
}
