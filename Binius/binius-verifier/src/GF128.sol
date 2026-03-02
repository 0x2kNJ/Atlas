// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "./BinaryFieldLibOpt.sol";

/// @title GF128 — GF(2^128) field arithmetic for binius64
/// @notice Thin wrapper that exposes the research-compatible GF128 API while
///         routing `mul` through the Zech-log optimised BinaryFieldLibOpt so
///         we get the same gas savings without changing any caller code.
///
///         Irreducible polynomial: x^128 + x^7 + x^2 + x + 1  (0x87 reduction)
///         This matches both BinaryFieldLibOpt and the original research GF128.
library GF128 {
    uint256 internal constant M128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    uint256 internal constant REDUCE = 0x87;

    // ── Arithmetic ────────────────────────────────────────────────────────────

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a ^ b;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a ^ b;
    }

    /// @notice GF(2^128) multiplication via the Zech-log table (fast path).
    ///         Falls back to software mul when either operand is zero.
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return BinaryFieldLibOpt.mulGF2_128(a & M128, b & M128);
    }

    function square(uint256 a) internal pure returns (uint256) {
        return mul(a, a);
    }

    function pow(uint256 base, uint256 exp) internal pure returns (uint256 result) {
        result = 1;
        base &= M128;
        while (exp > 0) {
            if (exp & 1 == 1) result = mul(result, base);
            base = mul(base, base);
            exp >>= 1;
        }
    }

    /// @notice Multiply by the generator x (left-shift + conditional reduce).
    function mulX(uint256 a) internal pure returns (uint256 c) {
        assembly {
            let m := 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
            let msb := and(shr(127, a), 1)
            c := and(shl(1, a), m)
            c := xor(c, mul(msb, 0x87))
        }
    }
}
