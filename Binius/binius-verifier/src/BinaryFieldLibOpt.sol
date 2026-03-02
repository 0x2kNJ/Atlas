// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import { BinaryFieldLib } from "./BinaryFieldLib.sol";

/// @title BinaryFieldLibOpt
/// @notice Optimized GF(2^128) arithmetic:
///   - All 7 tower levels inlined in Yul (no Solidity function call overhead)
///   - GF(2^8) base multiplication via Zech logarithm tables (generator = 19)
///     baked into bytecode as `bytes internal constant`, costing 3 MLOADs instead
///     of 63 XOR/AND operations per GF(2^8) multiply
///   - Montgomery batch inversion for FRI (1 full inversion + 3(n-1) multiplications)
///
///   Binius tower: GF(2^{2k}) = GF(2^k)[β] / (β² + β_{k-1}·β + 1)
///   mulAlpha_k(a_hi, a_lo) = (a_hi, a_lo ⊕ mulAlpha_{k-1}(a_hi))
///
///   GF(2^8) tables (generator g=19, verified exhaustively against BinaryFieldLib):
///     EXP_TABLE[i] = g^i,  LOG_TABLE[x] = i s.t. g^i=x,  LOG_TABLE[0] = 0xFF sentinel
library BinaryFieldLibOpt {

    // -----------------------------------------------------------------------
    //  GF(2^8) Zech logarithm tables — generator g = 19
    //  Verified: all 255*255 = 65025 non-zero products match BinaryFieldLib.mulGF256
    // -----------------------------------------------------------------------

    bytes internal constant EXP_TABLE =
        hex"01134366ab8c60c691ca59b26a63f453170ffabaee87d6e0"
        hex"6e2f684275e8eacb4af10cc87833d19e30e35cedb5143d38"
        hex"67b8cf066d1daa9f23a03a463974fba9ade17d6c0ee9f988"
        hex"2c5a80a8bea21bc782893f19e60332c2dd5648d08d7385f7"
        hex"61d5d2acf23e0aa565994ebd90d91ad4c1ef949586c5a308"
        hex"84e422b3792092f89b6f3c2b24de648a0ddb3b557a125025"
        hex"cd27eca6575b93ebd80997a74418f540546951368e41472a"
        hex"379d022181bbfdc4b04be24faed3bfb158a129055fdf77c9"
        hex"6b70b735bc839a7c7f4d8f52044c9c1162e71071a476da28"
        hex"161cb9dc450bb626ffe531f01f8b1e985dfef67296b4077e"
        hex"5ecc34afc0fcd7f32d49c3ce152e7b01";

    bytes internal constant LOG_TABLE =
        hex"ff00aa55ccbb33ee779966dd22884411d2cf8d012dfcd810"
        hex"9d536e4ed935e6e47dab7a38848fdf91d7baa78348f8fd19"
        hex"28e25625f2c3a3a82f3c3a8a822e65529fa51b029cdc3ba6"
        hex"5af920b1cdc96ab38ea2cb0fa08b5994b80a49952ae8f0bc"
        hex"0660d00d866803301aa10cc043341881c1d3eb5d3d1cd5be"
        hex"247c8cfec742efc84aac50c5785e7415475187e5055ca4ca"
        hex"6c087e967273ec9ae769c680cea9273739b94d76d467939b"
        hex"4b3f36046340b4f3b0b70b7bed2cdec231da13adc46b4cb6"
        hex"f47057faaf75074f23bf091ff190fb325b2662b56f6116f6"
        hex"986dd689db5885bd1741b22979e154d11d451e97922b1471"
        hex"e32164f70e9eea5f7f46123ef5aee9e0";

    // -----------------------------------------------------------------------
    //  GF(2^8) multiply via Zech tables — standalone, safe for any call site
    // -----------------------------------------------------------------------

    function mulGF256_table(uint256 a, uint256 b) internal pure returns (uint256 r) {
        if (a == 0 || b == 0) return 0;
        bytes memory exp_ = EXP_TABLE;
        bytes memory log_ = LOG_TABLE;
        assembly ("memory-safe") {
            let expData := add(exp_, 32)
            let logData := add(log_, 32)
            let la := byte(0, mload(add(logData, a)))
            let lb := byte(0, mload(add(logData, b)))
            let s := add(la, lb)
            if iszero(lt(s, 255)) { s := sub(s, 255) }
            r := byte(0, mload(add(expData, s)))
        }
    }

    // -----------------------------------------------------------------------
    //  GF(2^128) multiply — fully inlined Yul tower with table-backed GF(2^8) base
    //
    //  Architecture: the 7-level tower recurse as normal, but at level 3 (GF(2^8))
    //  instead of recursing into mul4→mul2, we do 3 MLOAD table lookups.
    //  The upper 4 levels (GF(2^16) through GF(2^128)) remain Karatsuba in Yul.
    //
    //  mulAlpha functions are still pure bitwise — no change needed there.
    // -----------------------------------------------------------------------

    function mulGF2_128(uint256 a, uint256 b) internal pure returns (uint256 result) {
        bytes memory exp_ = EXP_TABLE;
        bytes memory log_ = LOG_TABLE;
        assembly ("memory-safe") {
            // Table data pointers (EXP and LOG are 256-byte arrays)
            let expPtr := add(exp_, 32)
            let logPtr := add(log_, 32)

            // ================================================================
            // GF(2^128) = GF(2^64)[Y] / (Y^2 + β₆·Y + 1)
            //
            // Safety: mask inputs to 128 bits. GF(2^128) elements occupy bits
            // 0-127; bits 128-255 must be zero. Without masking, shr(64, a)
            // would leak bits 128-191 into a1, producing incorrect results for
            // any caller that passes a uint256 with non-zero upper bits.
            // ================================================================
            a := and(a, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            b := and(b, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            let a0 := and(a, 0xFFFFFFFFFFFFFFFF)
            let a1 := shr(64, a)
            let b0 := and(b, 0xFFFFFFFFFFFFFFFF)
            let b1 := shr(64, b)

            let p0 := _mul64(a0, b0, expPtr, logPtr)
            let p1 := _mul64(a1, b1, expPtr, logPtr)
            let pm := _mul64(xor(a0, a1), xor(b0, b1), expPtr, logPtr)
            let p1a := _mulA64(p1)

            result := or(xor(p0, p1), shl(64, xor(xor(xor(pm, p0), p1), p1a)))

            // ================================================================
            // Inner Yul functions: mul64, mul32, mul16, mul8(table), mulAlpha
            // Each takes (x, y, expPtr, logPtr) for levels that need mul8
            // ================================================================

            function _mul64(x, y, eP, lP) -> r {
                let x0 := and(x, 0xFFFFFFFF)
                let x1 := shr(32, x)
                let y0 := and(y, 0xFFFFFFFF)
                let y1 := shr(32, y)
                let pp0 := _mul32(x0, y0, eP, lP)
                let pp1 := _mul32(x1, y1, eP, lP)
                let ppm := _mul32(xor(x0, x1), xor(y0, y1), eP, lP)
                let pp1a := _mulA32(pp1)
                r := or(xor(pp0, pp1), shl(32, xor(xor(xor(ppm, pp0), pp1), pp1a)))
            }

            function _mul32(x, y, eP, lP) -> r {
                let x0 := and(x, 0xFFFF)
                let x1 := shr(16, x)
                let y0 := and(y, 0xFFFF)
                let y1 := shr(16, y)
                let pp0 := _mul16(x0, y0, eP, lP)
                let pp1 := _mul16(x1, y1, eP, lP)
                let ppm := _mul16(xor(x0, x1), xor(y0, y1), eP, lP)
                let pp1a := _mulA16(pp1)
                r := or(xor(pp0, pp1), shl(16, xor(xor(xor(ppm, pp0), pp1), pp1a)))
            }

            function _mul16(x, y, eP, lP) -> r {
                let x0 := and(x, 0xFF)
                let x1 := shr(8, x)
                let y0 := and(y, 0xFF)
                let y1 := shr(8, y)
                // At GF(2^8) base: use Zech log table
                let pp0 := _mul8_tbl(x0, y0, eP, lP)
                let pp1 := _mul8_tbl(x1, y1, eP, lP)
                let ppm := _mul8_tbl(xor(x0, x1), xor(y0, y1), eP, lP)
                let pp1a := _mulA8(pp1)
                r := or(xor(pp0, pp1), shl(8, xor(xor(xor(ppm, pp0), pp1), pp1a)))
            }

            // GF(2^8) multiply via Zech log table
            function _mul8_tbl(x, y, eP, lP) -> r {
                if or(iszero(x), iszero(y)) { leave }  // r = 0 by default
                let lx := byte(0, mload(add(lP, x)))
                let ly := byte(0, mload(add(lP, y)))
                let s := add(lx, ly)
                if iszero(lt(s, 255)) { s := sub(s, 255) }
                r := byte(0, mload(add(eP, s)))
            }

            // mulAlpha functions (pure bitwise, no table needed)
            function _mulA8(x) -> r {
                // mulAlpha_8(a1, a0) = (a1, a0 ^ mulAlpha_4(a1))
                let h := shr(4, x)
                let l := and(x, 0xF)
                r := or(h, shl(4, xor(l, _mulA4(h))))
            }

            function _mulA16(x) -> r {
                let h := shr(8, x)
                let l := and(x, 0xFF)
                r := or(h, shl(8, xor(l, _mulA8(h))))
            }

            function _mulA32(x) -> r {
                let h := shr(16, x)
                let l := and(x, 0xFFFF)
                r := or(h, shl(16, xor(l, _mulA16(h))))
            }

            function _mulA64(x) -> r {
                let h := shr(32, x)
                let l := and(x, 0xFFFFFFFF)
                r := or(h, shl(32, xor(l, _mulA32(h))))
            }

            function _mulA4(x) -> r {
                // mulAlpha at level 2 (GF(2^4)): multiply by β₂.
                // mulAlpha_2(a1, a0) = (a1, a0 ⊕ mulAlpha_1(a1))
                //   where mulAlpha_1 (level 1, GF(2^2)) is: (b1, b0) → (b1, b0 ⊕ b1)
                //
                // Base case of the recursion:
                //   mulAlpha_0(x) = x  (GF(2), multiply by 1 = identity, since β₀ = 1)
                //   mulAlpha_1(b1, b0) = (b1, b0 ⊕ mulAlpha_0(b1)) = (b1, b0 ⊕ b1)
                let h := shr(2, x)
                let l := and(x, 0x3)
                // mulAlpha_1(h): h_hi=shr(1,h), h_lo=and(h,1); result=(h_hi, h_lo⊕h_hi)
                let hh := shr(1, h)
                let hl := and(h, 1)
                let hAlpha := or(hh, shl(1, xor(hl, hh)))
                r := or(h, shl(2, xor(l, hAlpha)))
            }
        }
    }

    // -----------------------------------------------------------------------
    //  GF(2^128) square — inlined Yul with table-backed GF(2^8) base
    // -----------------------------------------------------------------------

    function squareGF2_128(uint256 a) internal pure returns (uint256 result) {
        bytes memory exp_ = EXP_TABLE;
        bytes memory log_ = LOG_TABLE;
        assembly ("memory-safe") {
            let expPtr := add(exp_, 32)
            let logPtr := add(log_, 32)

            // Mask to 128 bits for the same reason as mulGF2_128.
            a := and(a, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            let a0 := and(a, 0xFFFFFFFFFFFFFFFF)
            let a1 := shr(64, a)
            let s0 := _sq64(a0, expPtr, logPtr)
            let s1 := _sq64(a1, expPtr, logPtr)
            let s1a := _mulA64(s1)
            result := or(xor(s0, s1), shl(64, s1a))

            function _sq64(x, eP, lP) -> r {
                let x0 := and(x, 0xFFFFFFFF)
                let x1 := shr(32, x)
                let ss0 := _sq32(x0, eP, lP)
                let ss1 := _sq32(x1, eP, lP)
                r := or(xor(ss0, ss1), shl(32, _mulA32(ss1)))
            }

            function _sq32(x, eP, lP) -> r {
                let x0 := and(x, 0xFFFF)
                let x1 := shr(16, x)
                let ss0 := _sq16(x0, eP, lP)
                let ss1 := _sq16(x1, eP, lP)
                r := or(xor(ss0, ss1), shl(16, _mulA16(ss1)))
            }

            function _sq16(x, eP, lP) -> r {
                let x0 := and(x, 0xFF)
                let x1 := shr(8, x)
                // sq8(v) in GF(2^8): (x1^2, x0^2 ^ mulAlpha_4(x1^2))
                // But sq in GF(2^8) means: sq(a1,a0) = (sq(a0) ^ sq(a1), mulAlpha_4(sq(a1)))
                // We need sq8 which squares a GF(2^8) element.
                // sq in this tower: lo = sq(a0)^sq(a1), hi = mulAlpha(sq(a1))
                // sq in GF(2^4): lo = sq4(a0)^sq4(a1), hi = mulAlpha_4(sq4(a1))
                // ...down to sq in GF(2^2): lo = a0^a1, hi = a1
                // We can compute sq8(v) using the same squaring recursion
                let ss0 := _sq8_rec(x0)
                let ss1 := _sq8_rec(x1)
                r := or(xor(ss0, ss1), shl(8, _mulA8(ss1)))
            }

            // GF(2^8) square via recursion (squaring is always fast — no field mul needed)
            function _sq8_rec(x) -> r {
                let x0 := and(x, 0xF)
                let x1 := shr(4, x)
                let ss0 := _sq4(x0)
                let ss1 := _sq4(x1)
                r := or(xor(ss0, ss1), shl(4, _mulA4(ss1)))
            }

            function _sq4(x) -> r {
                let x0 := and(x, 0x3)
                let x1 := shr(2, x)
                let ss0 := _sq2(x0)
                let ss1 := _sq2(x1)
                r := or(xor(ss0, ss1), shl(2, _mulA2(ss1)))
            }

            function _sq2(x) -> r {
                let xa0 := and(x, 1)
                let xa1 := shr(1, x)
                r := or(xor(xa0, xa1), shl(1, xa1))
            }

            function _mulA2(x) -> r {
                let h := shr(1, x)
                let l := and(x, 1)
                r := or(h, shl(1, xor(l, h)))
            }

            function _mulA4(x) -> r {
                let h := shr(2, x)
                let l := and(x, 0x3)
                let hh := shr(1, h)
                let hl := and(h, 1)
                let hAlpha := or(hh, shl(1, xor(hl, hh)))
                r := or(h, shl(2, xor(l, hAlpha)))
            }

            function _mulA8(x) -> r {
                let h := shr(4, x)
                let l := and(x, 0xF)
                r := or(h, shl(4, xor(l, _mulA4(h))))
            }

            function _mulA16(x) -> r {
                let h := shr(8, x)
                let l := and(x, 0xFF)
                r := or(h, shl(8, xor(l, _mulA8(h))))
            }

            function _mulA32(x) -> r {
                let h := shr(16, x)
                let l := and(x, 0xFFFF)
                r := or(h, shl(16, xor(l, _mulA16(h))))
            }

            function _mulA64(x) -> r {
                let h := shr(32, x)
                let l := and(x, 0xFFFFFFFF)
                r := or(h, shl(32, xor(l, _mulA32(h))))
            }
        }
    }

    // -----------------------------------------------------------------------
    //  Montgomery batch inversion over GF(2^128)
    //
    //  Given n field elements a[0..n-1], returns their inverses using:
    //    1 full inversion (using BinaryFieldLib.invGF2_128)
    //    3(n-1) multiplications
    //
    //  Algorithm:
    //    prefix[i] = a[0] * a[1] * ... * a[i]
    //    inv_last = inv(prefix[n-1])
    //    for i = n-1 downto 1:
    //      result[i] = prefix[i-1] * inv_last
    //      inv_last  = inv_last * a[i]
    //    result[0] = inv_last
    //
    //  Cost: (n-1) muls for prefix + 1 inv + (n-1)*2 muls for backward pass
    //        = 3(n-1) muls + 1 inv  vs  n invs (baseline).
    //  For n=1280 (64 FRI queries × 20 rounds): saves 1279 invGF2_128 calls.
    // -----------------------------------------------------------------------

    /// @notice Batch invert with explicit original array.
    ///         Writes inverses into `results[i] = inv(inputs[i])`.
    ///         Zero inputs produce zero outputs.
    /// @dev Montgomery's trick: (n-1) prefix muls + 1 inversion + 2(n-1) muls.
    ///      For n=1280: replaces 1280 × invGF2_128 with 1 + 3837 × mulGF2_128.
    function batchInvertGF2_128(uint256[] memory inputs, uint256[] memory results)
        internal
        pure
    {
        uint256 n = inputs.length;
        require(results.length == n, "length mismatch");
        if (n == 0) return;
        if (n == 1) {
            results[0] = inputs[0] == 0 ? 0 : _invGF2_128(inputs[0]);
            return;
        }

        // Forward pass: prefix[i] = inputs[0] * inputs[1] * ... * inputs[i]
        // (skipping zeros — they are handled separately)
        uint256[] memory prefix = new uint256[](n);
        uint256 runningProd = 1;
        for (uint256 i = 0; i < n; i++) {
            if (inputs[i] != 0) runningProd = mulGF2_128(runningProd, inputs[i]);
            prefix[i] = runningProd;
        }

        // Single inversion of the total non-zero product
        uint256 invRunning = _invGF2_128(runningProd);

        // Backward pass: peel off one element at a time
        // Invariant: invRunning = inv(inputs[0] * ... * inputs[i])  (non-zero elements only)
        for (uint256 i = n; i > 0; ) {
            i--;
            if (inputs[i] == 0) {
                results[i] = 0;
                continue;
            }
            // inv(inputs[i]) = prefix[i-1] * invRunning
            uint256 prevPrefix = (i == 0) ? 1 : prefix[i - 1];
            results[i] = mulGF2_128(prevPrefix, invRunning);
            // Update: invRunning for next iteration = invRunning * inputs[i]
            //   because inv(prefix[i-1]) = inv(prefix[i]) * inputs[i] = invRunning * inputs[i]
            invRunning = mulGF2_128(invRunning, inputs[i]);
        }
    }

    // -----------------------------------------------------------------------
    //  Internal: GF(2^128) inversion.
    //  Delegates to BinaryFieldLib — inversion is the cold path (1 per batch).
    // -----------------------------------------------------------------------

    function _invGF2_128(uint256 a) private pure returns (uint256) {
        return BinaryFieldLib.invGF2_128(a);
    }

    // Legacy Yul inversion kept for reference (not used — wrong addition chain)
    function _invGF2_128_yul_unused(uint256 a) private pure returns (uint256 result) {
        bytes memory exp_ = EXP_TABLE;
        bytes memory log_ = LOG_TABLE;
        assembly ("memory-safe") {
            let eP := add(exp_, 32)
            let lP := add(log_, 32)

            // Square x n times
            function _sqN(x, n_, eP_, lP_) -> r {
                r := x
                for {} n_ {} {
                    r := _sq128(r, eP_, lP_)
                    n_ := sub(n_, 1)
                }
            }

            function _sq128(x, eP_, lP_) -> r {
                let a0 := and(x, 0xFFFFFFFFFFFFFFFF)
                let a1 := shr(64, x)
                let s0 := _sq64_inv(a0, eP_, lP_)
                let s1 := _sq64_inv(a1, eP_, lP_)
                let s1a := _mA64(s1)
                r := or(xor(s0, s1), shl(64, s1a))
            }

            function _sq64_inv(x, eP_, lP_) -> r {
                let x0 := and(x, 0xFFFFFFFF)
                let x1 := shr(32, x)
                let s0 := _sq32_inv(x0, eP_, lP_)
                let s1 := _sq32_inv(x1, eP_, lP_)
                r := or(xor(s0, s1), shl(32, _mA32(s1)))
            }

            function _sq32_inv(x, eP_, lP_) -> r {
                let x0 := and(x, 0xFFFF)
                let x1 := shr(16, x)
                let s0 := _sq16_inv(x0, eP_, lP_)
                let s1 := _sq16_inv(x1, eP_, lP_)
                r := or(xor(s0, s1), shl(16, _mA16(s1)))
            }

            function _sq16_inv(x, eP_, lP_) -> r {
                let x0 := and(x, 0xFF)
                let x1 := shr(8, x)
                let s0 := _sq8_inv(x0)
                let s1 := _sq8_inv(x1)
                r := or(xor(s0, s1), shl(8, _mA8(s1)))
            }

            function _sq8_inv(x) -> r {
                let x0 := and(x, 0xF)
                let x1 := shr(4, x)
                let s0 := _sq4_inv(x0)
                let s1 := _sq4_inv(x1)
                r := or(xor(s0, s1), shl(4, _mA4(s1)))
            }

            function _sq4_inv(x) -> r {
                let x0 := and(x, 0x3)
                let x1 := shr(2, x)
                let s0 := _sq2_inv(x0)
                let s1 := _sq2_inv(x1)
                r := or(xor(s0, s1), shl(2, _mA2(s1)))
            }

            function _sq2_inv(x) -> r {
                let xa0 := and(x, 1)
                let xa1 := shr(1, x)
                r := or(xor(xa0, xa1), shl(1, xa1))
            }

            function _mA2(x) -> r {
                let h := shr(1, x)
                r := or(h, shl(1, xor(and(x, 1), h)))
            }

            function _mA4(x) -> r {
                let h := shr(2, x)
                let l := and(x, 0x3)
                let hh := shr(1, h)
                let hl := and(h, 1)
                r := or(h, shl(2, xor(l, or(hh, shl(1, xor(hl, hh))))))
            }

            function _mA8(x) -> r {
                let h := shr(4, x)
                let l := and(x, 0xF)
                r := or(h, shl(4, xor(l, _mA4(h))))
            }

            function _mA16(x) -> r {
                let h := shr(8, x)
                let l := and(x, 0xFF)
                r := or(h, shl(8, xor(l, _mA8(h))))
            }

            function _mA32(x) -> r {
                let h := shr(16, x)
                let l := and(x, 0xFFFF)
                r := or(h, shl(16, xor(l, _mA16(h))))
            }

            function _mA64(x) -> r {
                let h := shr(32, x)
                let l := and(x, 0xFFFFFFFF)
                r := or(h, shl(32, xor(l, _mA32(h))))
            }

            function _mul128_inv(x, y, eP_, lP_) -> r {
                let x0 := and(x, 0xFFFFFFFFFFFFFFFF)
                let x1 := shr(64, x)
                let y0 := and(y, 0xFFFFFFFFFFFFFFFF)
                let y1 := shr(64, y)
                let pp0 := _m64(x0, y0, eP_, lP_)
                let pp1 := _m64(x1, y1, eP_, lP_)
                let ppm := _m64(xor(x0, x1), xor(y0, y1), eP_, lP_)
                let pp1a := _mA64(pp1)
                r := or(xor(pp0, pp1), shl(64, xor(xor(xor(ppm, pp0), pp1), pp1a)))
            }

            function _m64(x, y, eP_, lP_) -> r {
                let x0 := and(x, 0xFFFFFFFF)
                let x1 := shr(32, x)
                let y0 := and(y, 0xFFFFFFFF)
                let y1 := shr(32, y)
                let pp0 := _m32(x0, y0, eP_, lP_)
                let pp1 := _m32(x1, y1, eP_, lP_)
                let ppm := _m32(xor(x0, x1), xor(y0, y1), eP_, lP_)
                let pp1a := _mA32(pp1)
                r := or(xor(pp0, pp1), shl(32, xor(xor(xor(ppm, pp0), pp1), pp1a)))
            }

            function _m32(x, y, eP_, lP_) -> r {
                let x0 := and(x, 0xFFFF)
                let x1 := shr(16, x)
                let y0 := and(y, 0xFFFF)
                let y1 := shr(16, y)
                let pp0 := _m16(x0, y0, eP_, lP_)
                let pp1 := _m16(x1, y1, eP_, lP_)
                let ppm := _m16(xor(x0, x1), xor(y0, y1), eP_, lP_)
                let pp1a := _mA16(pp1)
                r := or(xor(pp0, pp1), shl(16, xor(xor(xor(ppm, pp0), pp1), pp1a)))
            }

            function _m16(x, y, eP_, lP_) -> r {
                let x0 := and(x, 0xFF)
                let x1 := shr(8, x)
                let y0 := and(y, 0xFF)
                let y1 := shr(8, y)
                let pp0 := _m8t(x0, y0, eP_, lP_)
                let pp1 := _m8t(x1, y1, eP_, lP_)
                let ppm := _m8t(xor(x0, x1), xor(y0, y1), eP_, lP_)
                let pp1a := _mA8(pp1)
                r := or(xor(pp0, pp1), shl(8, xor(xor(xor(ppm, pp0), pp1), pp1a)))
            }

            function _m8t(x, y, eP_, lP_) -> r {
                if or(iszero(x), iszero(y)) { leave }
                let lx := byte(0, mload(add(lP_, x)))
                let ly := byte(0, mload(add(lP_, y)))
                let s := add(lx, ly)
                if iszero(lt(s, 255)) { s := sub(s, 255) }
                r := byte(0, mload(add(eP_, s)))
            }

            // Itoh-Tsujii chain for GF(2^128) inverse
            // inv(a) = a^(2^128-2) uses the addition chain:
            // e = 2^128-2 = 2*(2^127-1)
            // We compute via repeated squaring + mul:
            //   b1   = a^(2^1-1)  = a
            //   b2   = b1^(2^1) * b1    = a^3
            //   b4   = b2^(2^2) * b2    = a^15
            //   b8   = b4^(2^4) * b4    = a^255     (= invGF256 power)
            //   b16  = b8^(2^8) * b8
            //   b32  = b16^(2^16) * b16
            //   b64  = b32^(2^32) * b32
            //   b127 = b64^(2^64) * b63   (careful)
            // Simplified addition chain:
            //   x1   = a
            //   x2   = sqN(x1,1) * x1   => a^3
            //   x4   = sqN(x2,2) * x2   => a^15
            //   x8   = sqN(x4,4) * x4   => a^255
            //   x16  = sqN(x8,8) * x8
            //   x32  = sqN(x16,16)*x16
            //   x64  = sqN(x32,32)*x32
            //   x127 = sqN(x64,63)*x1   (2^127-1)
            //   result = sqN(x127,1)     (a^(2^128-2) = inv)
            let x1 := a
            let x2 := _mul128_inv(_sqN(x1, 1, eP, lP), x1, eP, lP)
            let x4 := _mul128_inv(_sqN(x2, 2, eP, lP), x2, eP, lP)
            let x8 := _mul128_inv(_sqN(x4, 4, eP, lP), x4, eP, lP)
            let x16 := _mul128_inv(_sqN(x8, 8, eP, lP), x8, eP, lP)
            let x32 := _mul128_inv(_sqN(x16, 16, eP, lP), x16, eP, lP)
            let x64 := _mul128_inv(_sqN(x32, 32, eP, lP), x32, eP, lP)
            let x127 := _mul128_inv(_sqN(x64, 63, eP, lP), x1, eP, lP)
            result := _sqN(x127, 1, eP, lP)
        }
    }
}
