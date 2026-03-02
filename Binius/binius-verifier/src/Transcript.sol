// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

/// @title Transcript — SHA256 Fiat-Shamir transcript matching binius64's HasherChallenger
/// @notice Implements the exact same Fiat-Shamir transform used by binius64's
///         `HasherChallenger<Sha256>`. The challenger is a stateful hash sponge with two modes:
///
///         Observer mode: absorbs data into SHA256 (block-by-block)
///         Sampler mode: squeezes random bytes via finalize-and-feed-forward
///
///         Mode transitions:
///           Observer → Sampler: flush partial block, sampler starts with index=32 (triggers fill)
///           Sampler → Observer: feed sampler.index as LE u64 into hasher
///
///         Initialization: state = SHA256(""), hasher = SHA256.update(state)
///
///         This matches the Rust implementation in binius_transcript::fiat_shamir::hasher_challenger
///
///         Proof tape:
///           The proof bytes are read sequentially. The `message()` method reads from the proof
///           tape AND observes the bytes into the Fiat-Shamir state.
///           The `sample()` method squeezes random bytes from the Fiat-Shamir state.
library Transcript {
    uint256 internal constant SHA256_OUTPUT_SIZE = 32;
    uint256 internal constant SHA256_BLOCK_SIZE = 64;

    /// @dev We simplify the implementation: instead of tracking the full incremental SHA256
    ///      hasher state, we accumulate all observed data and re-hash when needed.
    ///      This is correct because SHA256(A || B) where |A| is block-aligned equals
    ///      incrementally hashing A then B.
    ///
    ///      For the EVM, we track:
    ///        - hasherData: all data fed to the hasher so far (unfinalized)
    ///        - samplerBuffer: 32-byte output from last finalize_reset
    ///        - samplerIndex: position within samplerBuffer
    ///        - isObserver: whether we're in observer or sampler mode
    ///        - proof/offset: proof tape
    struct State {
        bytes hasherData;       // accumulated data for SHA256 hasher
        bytes32 samplerBuffer;  // last hash output (sampling buffer)
        uint256 samplerIndex;   // bytes consumed from samplerBuffer
        bool isObserver;        // current mode
        bytes proof;            // full proof bytes
        uint256 offset;         // current read position in proof
    }

    /// @notice Initialize a transcript from proof bytes, matching HasherChallenger::default().
    ///         Initial state = SHA256(""), hasher starts with update(SHA256(""))
    function init(bytes memory proof) internal pure returns (State memory t) {
        // SHA256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        bytes32 emptyHash = hex"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

        // HasherChallenger starts in Sampler mode:
        //   sampler.hasher = SHA256.new().update(emptyHash)
        //   sampler.buffer = emptyHash
        //   sampler.index = 0
        t.hasherData = abi.encodePacked(emptyHash);
        t.samplerBuffer = emptyHash;
        t.samplerIndex = 0;
        t.isObserver = false; // starts in Sampler mode
        t.proof = proof;
        t.offset = 0;
    }

    // ── Proof-tape reads (also observe into Fiat-Shamir state) ──────────────

    /// @notice Read n bytes from the proof tape and observe them into the Fiat-Shamir state.
    function messageBytes(State memory t, uint256 n) internal pure returns (bytes memory data) {
        require(t.offset + n <= t.proof.length, "Transcript: read past end");
        data = new bytes(n);
        bytes memory proof = t.proof;
        uint256 srcOff = t.offset;
        assembly {
            let src := add(add(proof, 32), srcOff)
            let dst := add(data, 32)
            for { let i := 0 } lt(i, n) { i := add(i, 32) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
        }
        t.offset = srcOff + n;
        _observe(t, data);
    }

    /// @notice Read a single GF128 element (16 bytes, little-endian) from proof tape.
    function messageGF128(State memory t) internal pure returns (uint256 val) {
        require(t.offset + 16 <= t.proof.length, "Transcript: read past end");
        bytes memory proof = t.proof;
        uint256 off = t.offset;
        assembly {
            let raw := mload(add(add(proof, 32), off))
            let b := shr(128, raw) // top 16 bytes as a uint128

            // Byte-reverse 16 bytes: convert memory-BE to LE u128
            val := 0
            val := or(val, shl(120, and(b, 0xff)))
            val := or(val, shl(112, and(shr(8, b), 0xff)))
            val := or(val, shl(104, and(shr(16, b), 0xff)))
            val := or(val, shl(96, and(shr(24, b), 0xff)))
            val := or(val, shl(88, and(shr(32, b), 0xff)))
            val := or(val, shl(80, and(shr(40, b), 0xff)))
            val := or(val, shl(72, and(shr(48, b), 0xff)))
            val := or(val, shl(64, and(shr(56, b), 0xff)))
            val := or(val, shl(56, and(shr(64, b), 0xff)))
            val := or(val, shl(48, and(shr(72, b), 0xff)))
            val := or(val, shl(40, and(shr(80, b), 0xff)))
            val := or(val, shl(32, and(shr(88, b), 0xff)))
            val := or(val, shl(24, and(shr(96, b), 0xff)))
            val := or(val, shl(16, and(shr(104, b), 0xff)))
            val := or(val, shl(8, and(shr(112, b), 0xff)))
            val := or(val, and(shr(120, b), 0xff))
        }
        t.offset = off + 16;

        bytes memory raw = new bytes(16);
        assembly {
            let src := add(add(proof, 32), off)
            let dst := add(raw, 32)
            mstore(dst, mload(src))
        }
        _observe(t, raw);
    }

    /// @notice Read a 32-byte digest from the proof tape and observe it.
    function messageBytes32(State memory t) internal pure returns (bytes32 val) {
        require(t.offset + 32 <= t.proof.length, "Transcript: read past end");
        bytes memory proof = t.proof;
        uint256 off = t.offset;
        assembly {
            val := mload(add(add(proof, 32), off))
        }
        t.offset = off + 32;

        bytes memory raw = new bytes(32);
        assembly {
            mstore(add(raw, 32), val)
        }
        _observe(t, raw);
    }

    // ── Sampling (squeeze) ───────────────────────────────────────────────────

    /// @notice Sample n bytes of randomness from the Fiat-Shamir state.
    function sampleBytes(State memory t, uint256 n) internal view returns (bytes memory out) {
        _switchToSampler(t);

        out = new bytes(n);
        uint256 written = 0;

        while (written < n) {
            if (t.samplerIndex >= SHA256_OUTPUT_SIZE) {
                _fillSamplerBuffer(t);
            }

            uint256 available = SHA256_OUTPUT_SIZE - t.samplerIndex;
            uint256 toRead = n - written < available ? n - written : available;

            bytes32 buf = t.samplerBuffer;
            uint256 idx = t.samplerIndex;
            for (uint256 i = 0; i < toRead; i++) {
                out[written + i] = bytes1(buf[idx + i]);
            }

            t.samplerIndex += toRead;
            written += toRead;
        }
    }

    /// @notice Sample a GF128 challenge (16 bytes, interpreted as LE u128).
    function sampleGF128(State memory t) internal view returns (uint256 val) {
        bytes memory raw = sampleBytes(t, 16);
        assembly {
            let b := mload(add(raw, 32))
            b := shr(128, b)

            val := 0
            val := or(val, shl(120, and(b, 0xff)))
            val := or(val, shl(112, and(shr(8, b), 0xff)))
            val := or(val, shl(104, and(shr(16, b), 0xff)))
            val := or(val, shl(96, and(shr(24, b), 0xff)))
            val := or(val, shl(88, and(shr(32, b), 0xff)))
            val := or(val, shl(80, and(shr(40, b), 0xff)))
            val := or(val, shl(72, and(shr(48, b), 0xff)))
            val := or(val, shl(64, and(shr(56, b), 0xff)))
            val := or(val, shl(56, and(shr(64, b), 0xff)))
            val := or(val, shl(48, and(shr(72, b), 0xff)))
            val := or(val, shl(40, and(shr(80, b), 0xff)))
            val := or(val, shl(32, and(shr(88, b), 0xff)))
            val := or(val, shl(24, and(shr(96, b), 0xff)))
            val := or(val, shl(16, and(shr(104, b), 0xff)))
            val := or(val, shl(8, and(shr(112, b), 0xff)))
            val := or(val, and(shr(120, b), 0xff))
        }
    }

    /// @notice Check that the entire proof has been consumed.
    function finalize(State memory t) internal pure {
        require(t.offset == t.proof.length, "Transcript: unconsumed proof bytes");
    }

    // ── Decommitment reads (proof tape only, NOT observed) ──────────────────

    /// @notice Read a GF128 element WITHOUT observing (decommitment value).
    function decommitGF128(State memory t) internal pure returns (uint256 val) {
        require(t.offset + 16 <= t.proof.length, "Transcript: read past end");
        bytes memory proof = t.proof;
        uint256 off = t.offset;
        assembly {
            let raw := mload(add(add(proof, 32), off))
            let b := shr(128, raw)
            val := 0
            val := or(val, shl(120, and(b, 0xff)))
            val := or(val, shl(112, and(shr(8, b), 0xff)))
            val := or(val, shl(104, and(shr(16, b), 0xff)))
            val := or(val, shl(96, and(shr(24, b), 0xff)))
            val := or(val, shl(88, and(shr(32, b), 0xff)))
            val := or(val, shl(80, and(shr(40, b), 0xff)))
            val := or(val, shl(72, and(shr(48, b), 0xff)))
            val := or(val, shl(64, and(shr(56, b), 0xff)))
            val := or(val, shl(56, and(shr(64, b), 0xff)))
            val := or(val, shl(48, and(shr(72, b), 0xff)))
            val := or(val, shl(40, and(shr(80, b), 0xff)))
            val := or(val, shl(32, and(shr(88, b), 0xff)))
            val := or(val, shl(24, and(shr(96, b), 0xff)))
            val := or(val, shl(16, and(shr(104, b), 0xff)))
            val := or(val, shl(8, and(shr(112, b), 0xff)))
            val := or(val, and(shr(120, b), 0xff))
        }
        t.offset = off + 16;
    }

    /// @notice Read a 32-byte digest WITHOUT observing (decommitment value).
    function decommitBytes32(State memory t) internal pure returns (bytes32 val) {
        require(t.offset + 32 <= t.proof.length, "Transcript: read past end");
        bytes memory proof = t.proof;
        uint256 off = t.offset;
        assembly {
            val := mload(add(add(proof, 32), off))
        }
        t.offset = off + 32;
    }

    // ── Legacy API (backward compat with existing tests) ────────────────────

    function observe(State memory t, bytes memory data) internal pure {
        _observe(t, data);
    }

    function challengeGF128(State memory t) internal view returns (uint256) {
        return sampleGF128(t);
    }

    function readGF128(State memory t) internal pure returns (uint256) {
        return messageGF128(t);
    }

    function readBytes32(State memory t) internal view returns (bytes32) {
        return messageBytes32(t);
    }

    function observeBytes32(State memory t, bytes32 val) internal pure {
        bytes memory data = new bytes(32);
        assembly { mstore(add(data, 32), val) }
        _observe(t, data);
    }

    function challengeBytes32(State memory t) internal view returns (bytes32) {
        bytes memory raw = sampleBytes(t, 32);
        bytes32 result;
        assembly { result := mload(add(raw, 32)) }
        return result;
    }

    function readRaw(State memory t, uint256 n) internal pure returns (bytes memory data) {
        require(t.offset + n <= t.proof.length, "Transcript: read past end");
        data = new bytes(n);
        bytes memory proof = t.proof;
        uint256 srcOff = t.offset;
        assembly {
            let src := add(add(proof, 32), srcOff)
            let dst := add(data, 32)
            for { let i := 0 } lt(i, n) { i := add(i, 32) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
        }
        t.offset = srcOff + n;
    }

    // ─── Internal: Fiat-Shamir state machine ─────────────────────────────────

    function _observe(State memory t, bytes memory data) private pure {
        if (!t.isObserver) {
            _switchToObserver(t);
        }
        t.hasherData = abi.encodePacked(t.hasherData, data);
    }

    function _switchToObserver(State memory t) private pure {
        if (t.isObserver) return;

        bytes memory indexBytes = new bytes(8);
        uint256 idx = t.samplerIndex;
        assembly {
            let ptr := add(indexBytes, 32)
            mstore8(ptr,           and(idx, 0xff))
            mstore8(add(ptr, 1),   and(shr(8,  idx), 0xff))
            mstore8(add(ptr, 2),   and(shr(16, idx), 0xff))
            mstore8(add(ptr, 3),   and(shr(24, idx), 0xff))
            mstore8(add(ptr, 4),   and(shr(32, idx), 0xff))
            mstore8(add(ptr, 5),   and(shr(40, idx), 0xff))
            mstore8(add(ptr, 6),   and(shr(48, idx), 0xff))
            mstore8(add(ptr, 7),   and(shr(56, idx), 0xff))
        }
        t.hasherData = abi.encodePacked(t.hasherData, indexBytes);
        t.isObserver = true;
    }

    function _switchToSampler(State memory t) private pure {
        if (!t.isObserver) return;
        t.samplerIndex = SHA256_OUTPUT_SIZE;
        t.isObserver = false;
    }

    function _fillSamplerBuffer(State memory t) private view {
        bytes32 digest = _sha256(t.hasherData);
        t.samplerBuffer = digest;
        t.samplerIndex = 0;
        t.hasherData = abi.encodePacked(digest);
    }

    function _sha256(bytes memory data) private view returns (bytes32 result) {
        assembly {
            let len := mload(data)
            let ok := staticcall(gas(), 0x02, add(data, 32), len, 0x00, 32)
            if iszero(ok) { revert(0, 0) }
            result := mload(0x00)
        }
    }
}
