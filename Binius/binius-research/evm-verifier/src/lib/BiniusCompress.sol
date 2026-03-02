// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

/// @title BiniusCompress -- SHA256 compression function with binius domain-separated IV
/// @notice Implements the raw SHA256 block compression function (without length padding)
///         used by binius for Merkle tree internal nodes.
///
///         IV = bytemuck::cast::<[u8;32], [u32;8]>(SHA256("BINIUS SHA-256 COMPRESS"))
///         compress(left, right) = sha256_compress(IV, left || right) → LE word bytes
///
///         This differs from full SHA256(left || right) which adds padding and
///         processes a second block. The output uses LE word format (native x86),
///         matching binius's `must_cast::<[u32;8], [u8;32]>` serialization.
library BiniusCompress {

    /// @notice Compute binius Merkle node hash: compress(IV, left || right)
    /// @param left   Left child digest (32 bytes)
    /// @param right  Right child digest (32 bytes)
    /// @return result Compressed digest (32 bytes, LE word format)
    function compress(bytes32 left, bytes32 right) internal pure returns (bytes32 result) {
        assembly {
            // ── SHA256 round constants K[0..63] ──
            // Stored in scratch memory starting at 0x200
            let kPtr := 0x200
            mstore(add(kPtr, 0x00), 0x428a2f9871374491b5c0fbcfe9b5dba5)
            mstore(add(kPtr, 0x10), 0x3956c25b59f111f1923f82a4ab1c5ed5)
            mstore(add(kPtr, 0x20), 0xd807aa9812835b01243185be550c7dc3)
            mstore(add(kPtr, 0x30), 0x72be5d7480deb1fe9bdc06a7c19bf174)
            mstore(add(kPtr, 0x40), 0xe49b69c1efbe4786fc19dc60240ca1cc)
            mstore(add(kPtr, 0x50), 0x2de92c6f4a7484aa5cb0a9dc76f988da)
            mstore(add(kPtr, 0x60), 0x983e5152a831c66db00327c8bf597fc7)
            mstore(add(kPtr, 0x70), 0xc6e00bf3d5a7914706ca635114292967)
            mstore(add(kPtr, 0x80), 0x27b70a852e1b21384d2c6dfc53380d13)
            mstore(add(kPtr, 0x90), 0x650a7354766a0abb81c2c92e92722c85)
            mstore(add(kPtr, 0xa0), 0xa2bfe8a1a81a664bc24b8b70c76c51a3)
            mstore(add(kPtr, 0xb0), 0xd192e819d6990624f40e3585106aa070)
            mstore(add(kPtr, 0xc0), 0x19a4c116199e5e7332b16c6e681d831e)
            mstore(add(kPtr, 0xd0), 0x0fc19dc6240ca1cc2de92c6f4a7484aa)
            // Wait, I need to store all 64 K values properly. Each K is 32 bits.
            // Let me store them as individual u32 values.

            // Actually, let me use a cleaner approach.
            // Free memory pointer is at 0x40. Let's use high memory.
            let scratch := mload(0x40)
            // Reserve space: 64 K values × 4 bytes + 64 W values × 4 bytes + working vars
            // Actually let me put everything on the stack / in memory carefully.

            // ── Parse left||right as 16 big-endian u32 words (W[0..15]) ──
            // SHA256 parses the 64-byte block as 16 BE u32 words
            // W[0] = left[0..4] as BE u32, W[1] = left[4..8], ..., W[8] = right[0..4], ...

            // Store left and right into contiguous memory
            let blockPtr := scratch
            mstore(blockPtr, left)
            mstore(add(blockPtr, 0x20), right)

            // Parse into 16 BE u32 words
            // Each word is 4 bytes from the block, in big-endian order
            // Since mload already reads in BE order, we just need to extract each 4-byte group

            // Helper: read BE u32 from memory at byte offset
            function readBE32(base, byteOff) -> val {
                let raw := mload(add(base, byteOff))
                val := shr(224, raw) // top 4 bytes
            }

            // ── Message schedule W[0..63] ──
            // Store W in memory starting at scratch + 64
            let wPtr := add(scratch, 0x40)

            // W[0..15] from block
            for { let i := 0 } lt(i, 16) { i := add(i, 1) } {
                let w := readBE32(blockPtr, mul(i, 4))
                mstore(add(wPtr, mul(i, 0x20)), w)
            }

            // Helper functions for message schedule
            function rotr32(x, n) -> r {
                r := or(shr(n, and(x, 0xffffffff)), and(shl(sub(32, n), x), 0xffffffff))
            }

            function sigma0(x) -> r {
                r := xor(xor(rotr32(x, 7), rotr32(x, 18)), shr(3, and(x, 0xffffffff)))
            }

            function sigma1(x) -> r {
                r := xor(xor(rotr32(x, 17), rotr32(x, 19)), shr(10, and(x, 0xffffffff)))
            }

            // W[16..63]
            for { let i := 16 } lt(i, 64) { i := add(i, 1) } {
                let w16 := mload(add(wPtr, mul(sub(i, 16), 0x20)))
                let w15 := mload(add(wPtr, mul(sub(i, 15), 0x20)))
                let w7  := mload(add(wPtr, mul(sub(i,  7), 0x20)))
                let w2  := mload(add(wPtr, mul(sub(i,  2), 0x20)))
                let w := and(add(add(add(sigma1(w2), w7), sigma0(w15)), w16), 0xffffffff)
                mstore(add(wPtr, mul(i, 0x20)), w)
            }

            // ── Binius IV (LE u32 interpretation of SHA256("BINIUS SHA-256 COMPRESS")) ──
            // H[0]=0x16684ff5 H[1]=0x53a717d2 H[2]=0x1d4154c8 H[3]=0x574f1b56
            // H[4]=0xa37e524e H[5]=0xf12dfd41 H[6]=0x6303f932 H[7]=0x3754018c
            let a := 0x16684ff5
            let b := 0x53a717d2
            let c := 0x1d4154c8
            let d := 0x574f1b56
            let e := 0xa37e524e
            let f := 0xf12dfd41
            let g := 0x6303f932
            let h := 0x3754018c

            // Save initial state for final addition
            let a0 := a
            let b0 := b
            let c0 := c
            let d0 := d
            let e0 := e
            let f0 := f
            let g0 := g
            let h0 := h

            // ── SHA256 round constants (all 64) ──
            // Store as a lookup table in memory
            let kBase := add(wPtr, mul(64, 0x20))
            // K values
            mstore(add(kBase, 0x000), 0x428a2f98) mstore(add(kBase, 0x020), 0x71374491)
            mstore(add(kBase, 0x040), 0xb5c0fbcf) mstore(add(kBase, 0x060), 0xe9b5dba5)
            mstore(add(kBase, 0x080), 0x3956c25b) mstore(add(kBase, 0x0a0), 0x59f111f1)
            mstore(add(kBase, 0x0c0), 0x923f82a4) mstore(add(kBase, 0x0e0), 0xab1c5ed5)
            mstore(add(kBase, 0x100), 0xd807aa98) mstore(add(kBase, 0x120), 0x12835b01)
            mstore(add(kBase, 0x140), 0x243185be) mstore(add(kBase, 0x160), 0x550c7dc3)
            mstore(add(kBase, 0x180), 0x72be5d74) mstore(add(kBase, 0x1a0), 0x80deb1fe)
            mstore(add(kBase, 0x1c0), 0x9bdc06a7) mstore(add(kBase, 0x1e0), 0xc19bf174)
            mstore(add(kBase, 0x200), 0xe49b69c1) mstore(add(kBase, 0x220), 0xefbe4786)
            mstore(add(kBase, 0x240), 0x0fc19dc6) mstore(add(kBase, 0x260), 0x240ca1cc)
            mstore(add(kBase, 0x280), 0x2de92c6f) mstore(add(kBase, 0x2a0), 0x4a7484aa)
            mstore(add(kBase, 0x2c0), 0x5cb0a9dc) mstore(add(kBase, 0x2e0), 0x76f988da)
            mstore(add(kBase, 0x300), 0x983e5152) mstore(add(kBase, 0x320), 0xa831c66d)
            mstore(add(kBase, 0x340), 0xb00327c8) mstore(add(kBase, 0x360), 0xbf597fc7)
            mstore(add(kBase, 0x380), 0xc6e00bf3) mstore(add(kBase, 0x3a0), 0xd5a79147)
            mstore(add(kBase, 0x3c0), 0x06ca6351) mstore(add(kBase, 0x3e0), 0x14292967)
            mstore(add(kBase, 0x400), 0x27b70a85) mstore(add(kBase, 0x420), 0x2e1b2138)
            mstore(add(kBase, 0x440), 0x4d2c6dfc) mstore(add(kBase, 0x460), 0x53380d13)
            mstore(add(kBase, 0x480), 0x650a7354) mstore(add(kBase, 0x4a0), 0x766a0abb)
            mstore(add(kBase, 0x4c0), 0x81c2c92e) mstore(add(kBase, 0x4e0), 0x92722c85)
            mstore(add(kBase, 0x500), 0xa2bfe8a1) mstore(add(kBase, 0x520), 0xa81a664b)
            mstore(add(kBase, 0x540), 0xc24b8b70) mstore(add(kBase, 0x560), 0xc76c51a3)
            mstore(add(kBase, 0x580), 0xd192e819) mstore(add(kBase, 0x5a0), 0xd6990624)
            mstore(add(kBase, 0x5c0), 0xf40e3585) mstore(add(kBase, 0x5e0), 0x106aa070)
            mstore(add(kBase, 0x600), 0x19a4c116) mstore(add(kBase, 0x620), 0x1e376c08)
            mstore(add(kBase, 0x640), 0x2748774c) mstore(add(kBase, 0x660), 0x34b0bcb5)
            mstore(add(kBase, 0x680), 0x391c0cb3) mstore(add(kBase, 0x6a0), 0x4ed8aa4a)
            mstore(add(kBase, 0x6c0), 0x5b9cca4f) mstore(add(kBase, 0x6e0), 0x682e6ff3)
            mstore(add(kBase, 0x700), 0x748f82ee) mstore(add(kBase, 0x720), 0x78a5636f)
            mstore(add(kBase, 0x740), 0x84c87814) mstore(add(kBase, 0x760), 0x8cc70208)
            mstore(add(kBase, 0x780), 0x90befffa) mstore(add(kBase, 0x7a0), 0xa4506ceb)
            mstore(add(kBase, 0x7c0), 0xbef9a3f7) mstore(add(kBase, 0x7e0), 0xc67178f2)

            // ── 64 compression rounds ──
            function bigSigma0(x) -> r {
                r := xor(xor(rotr32(x, 2), rotr32(x, 13)), rotr32(x, 22))
            }

            function bigSigma1(x) -> r {
                r := xor(xor(rotr32(x, 6), rotr32(x, 11)), rotr32(x, 25))
            }

            function ch(x, y, z) -> r {
                r := xor(and(x, y), and(not(x), z))
                r := and(r, 0xffffffff)
            }

            function maj(x, y, z) -> r {
                r := xor(xor(and(x, y), and(x, z)), and(y, z))
                r := and(r, 0xffffffff)
            }

            for { let i := 0 } lt(i, 64) { i := add(i, 1) } {
                let ki := mload(add(kBase, mul(i, 0x20)))
                let wi := mload(add(wPtr, mul(i, 0x20)))

                let t1 := and(add(add(add(add(h, bigSigma1(e)), ch(e, f, g)), ki), wi), 0xffffffff)
                let t2 := and(add(bigSigma0(a), maj(a, b, c)), 0xffffffff)

                h := g
                g := f
                f := e
                e := and(add(d, t1), 0xffffffff)
                d := c
                c := b
                b := a
                a := and(add(t1, t2), 0xffffffff)
            }

            // ── Add round result to initial state ──
            a := and(add(a, a0), 0xffffffff)
            b := and(add(b, b0), 0xffffffff)
            c := and(add(c, c0), 0xffffffff)
            d := and(add(d, d0), 0xffffffff)
            e := and(add(e, e0), 0xffffffff)
            f := and(add(f, f0), 0xffffffff)
            g := and(add(g, g0), 0xffffffff)
            h := and(add(h, h0), 0xffffffff)

            // ── Convert to LE bytes (binius format: must_cast::<[u32;8], [u8;32]>) ──
            // Each u32 is stored as 4 LE bytes
            let outPtr := add(scratch, 0x2000) // safe memory area
            // a (state[0]) as LE bytes
            mstore8(add(outPtr,  0), and(a, 0xff))
            mstore8(add(outPtr,  1), and(shr(8, a), 0xff))
            mstore8(add(outPtr,  2), and(shr(16, a), 0xff))
            mstore8(add(outPtr,  3), and(shr(24, a), 0xff))
            mstore8(add(outPtr,  4), and(b, 0xff))
            mstore8(add(outPtr,  5), and(shr(8, b), 0xff))
            mstore8(add(outPtr,  6), and(shr(16, b), 0xff))
            mstore8(add(outPtr,  7), and(shr(24, b), 0xff))
            mstore8(add(outPtr,  8), and(c, 0xff))
            mstore8(add(outPtr,  9), and(shr(8, c), 0xff))
            mstore8(add(outPtr, 10), and(shr(16, c), 0xff))
            mstore8(add(outPtr, 11), and(shr(24, c), 0xff))
            mstore8(add(outPtr, 12), and(d, 0xff))
            mstore8(add(outPtr, 13), and(shr(8, d), 0xff))
            mstore8(add(outPtr, 14), and(shr(16, d), 0xff))
            mstore8(add(outPtr, 15), and(shr(24, d), 0xff))
            mstore8(add(outPtr, 16), and(e, 0xff))
            mstore8(add(outPtr, 17), and(shr(8, e), 0xff))
            mstore8(add(outPtr, 18), and(shr(16, e), 0xff))
            mstore8(add(outPtr, 19), and(shr(24, e), 0xff))
            mstore8(add(outPtr, 20), and(f, 0xff))
            mstore8(add(outPtr, 21), and(shr(8, f), 0xff))
            mstore8(add(outPtr, 22), and(shr(16, f), 0xff))
            mstore8(add(outPtr, 23), and(shr(24, f), 0xff))
            mstore8(add(outPtr, 24), and(g, 0xff))
            mstore8(add(outPtr, 25), and(shr(8, g), 0xff))
            mstore8(add(outPtr, 26), and(shr(16, g), 0xff))
            mstore8(add(outPtr, 27), and(shr(24, g), 0xff))
            mstore8(add(outPtr, 28), and(h, 0xff))
            mstore8(add(outPtr, 29), and(shr(8, h), 0xff))
            mstore8(add(outPtr, 30), and(shr(16, h), 0xff))
            mstore8(add(outPtr, 31), and(shr(24, h), 0xff))

            result := mload(outPtr)
        }
    }
}
