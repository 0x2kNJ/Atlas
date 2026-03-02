// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

/// @title GF128 — GF(2^128) GHASH field arithmetic (standard polynomial convention)
/// @notice Implements arithmetic in the BinaryField128bGhash field used by binius64.
///         Irreducible polynomial: p(x) = x^128 + x^7 + x^2 + x + 1
///         Bit i of the u128 value = coefficient of x^i (standard polynomial basis).
///         mulX is left-shift: (a << 1) ^ (0x87 if bit 127 was set).
///         Elements are stored as uint256 but only the low 128 bits are meaningful.
library GF128 {
    uint256 internal constant REDUCE = 0x87;
    uint256 internal constant M128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    function add(uint256 a, uint256 b) internal pure returns (uint256 c) {
        assembly {
            c := xor(a, b)
        }
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256 c) {
        assembly {
            c := xor(a, b)
        }
    }

    /// @notice Multiplication in GF(2^128) via MSB-first Horner evaluation.
    /// @dev Iterates bits of `a` from 127 down to 0. At each step:
    ///      result = result * x (left-shift + reduce), then XOR b if bit is set.
    ///      This computes a(x) * b mod p(x).
    function mul(uint256 a, uint256 b) internal pure returns (uint256 c) {
        assembly {
            let m := 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
            a := and(a, m)
            b := and(b, m)

            let result := 0
            for { let i := 127 } lt(i, 128) { i := sub(i, 1) } {
                let msb := and(shr(127, result), 1)
                result := and(shl(1, result), m)
                result := xor(result, mul(msb, 0x87))

                let bitSet := and(shr(i, a), 1)
                result := xor(result, mul(bitSet, b))
            }

            c := result
        }
    }

    function square(uint256 a) internal pure returns (uint256) {
        return mul(a, a);
    }

    function pow(uint256 base, uint256 exp) internal pure returns (uint256 result) {
        result = 1;
        while (exp > 0) {
            if (exp & 1 == 1) {
                result = mul(result, base);
            }
            base = mul(base, base);
            exp >>= 1;
        }
    }

    /// @notice Multiply by x (left-shift + conditional reduce by 0x87).
    function mulX(uint256 a) internal pure returns (uint256 c) {
        assembly {
            let m := 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
            let msb := and(shr(127, a), 1)
            c := and(shl(1, a), m)
            c := xor(c, mul(msb, 0x87))
        }
    }
}
