// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

/// @title FiatShamirTranscript
/// @notice Keccak256-based Fiat-Shamir transcript for non-interactive proofs.
///
///   The transcript absorbs prover messages (byte strings) and squeezes
///   verifier challenges as binary tower field elements. The state is a
///   running keccak256 hash that incorporates all absorbed data.
///
///   Protocol:
///     1. absorb(data)       — mix prover bytes into the state
///     2. squeeze128()       — extract a GF(2^128) challenge
///     3. squeezeN(n)        — extract n field challenges at once
///
///   The squeeze domain-separates from absorb by hashing the state with
///   a mode byte, preventing length-extension and squeeze/absorb confusion.
library FiatShamirTranscript {
    struct Transcript {
        bytes32 state;
        uint256 squeezeCounter;
    }

    function init() internal pure returns (Transcript memory t) {
        t.state = keccak256(abi.encodePacked("binius64-solidity-transcript-v1"));
        t.squeezeCounter = 0;
    }

    function initWithDomainSep(bytes memory label) internal pure returns (Transcript memory t) {
        t.state = keccak256(abi.encodePacked("binius64-solidity-transcript-v1", label));
        t.squeezeCounter = 0;
    }

    /// @notice Absorb arbitrary bytes into the transcript.
    function absorb(Transcript memory t, bytes memory data) internal pure {
        t.state = keccak256(abi.encodePacked(uint8(0x00), t.state, data));
        t.squeezeCounter = 0;
    }

    /// @notice Absorb a single bytes32 value (e.g., a commitment hash).
    function absorbBytes32(Transcript memory t, bytes32 val) internal pure {
        t.state = keccak256(abi.encodePacked(uint8(0x00), t.state, val));
        t.squeezeCounter = 0;
    }

    /// @notice Absorb a uint256 value (e.g., a field element or proof component).
    function absorbUint256(Transcript memory t, uint256 val) internal pure {
        t.state = keccak256(abi.encodePacked(uint8(0x00), t.state, val));
        t.squeezeCounter = 0;
    }

    /// @notice Squeeze a 128-bit challenge as a GF(2^128) element.
    /// @dev Domain separation:
    ///      - Mode byte 0x01 distinguishes squeeze from absorb (0x00), preventing
    ///        cross-mode collisions even if prover-supplied data equals 0x01||state.
    ///      - squeezeCounter increments on each call so consecutive squeezes from
    ///        the same state produce independent challenges: squeeze[i] uses counter=i.
    ///      - absorb() resets squeezeCounter to 0, so the first squeeze after an
    ///        absorb always uses counter=0. This means two transcripts that absorb
    ///        the same sequence produce the same challenges regardless of any
    ///        intermediate squeezes — squeezes are read-only with respect to state.
    ///      - The output is masked to 128 bits; the discarded upper 128 bits are
    ///        statistically independent of the returned value (separate keccak output).
    function squeeze128(Transcript memory t) internal pure returns (uint256) {
        bytes32 h = keccak256(
            abi.encodePacked(uint8(0x01), t.state, t.squeezeCounter)
        );
        t.squeezeCounter++;
        return uint256(h) & ((1 << 128) - 1);
    }

    /// @notice Squeeze a 64-bit challenge as a GF(2^64) element.
    function squeeze64(Transcript memory t) internal pure returns (uint256) {
        bytes32 h = keccak256(
            abi.encodePacked(uint8(0x01), t.state, t.squeezeCounter)
        );
        t.squeezeCounter++;
        return uint256(h) & ((1 << 64) - 1);
    }

    /// @notice Squeeze n independent GF(2^128) challenges.
    function squeezeN128(Transcript memory t, uint256 n) internal pure returns (uint256[] memory) {
        uint256[] memory challenges = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            challenges[i] = squeeze128(t);
        }
        return challenges;
    }

    /// @notice Absorb a sequence of uint256 values.
    function absorbMany(Transcript memory t, uint256[] memory vals) internal pure {
        for (uint256 i = 0; i < vals.length; i++) {
            t.state = keccak256(abi.encodePacked(uint8(0x00), t.state, vals[i]));
        }
        t.squeezeCounter = 0;
    }
}
