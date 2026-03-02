// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "./Types.sol";

/// @title HashLib
/// @notice Canonical EIP-712 struct hashing for all Atlas Protocol types.
///
/// Both CapabilityKernel and EnvelopeRegistry import this library.
/// Any change to a struct's type string or hashing logic must be made here — not
/// duplicated per-contract. The single-source rule prevents the type hash mismatch
/// that would cause signature verification to silently produce wrong digests.

library HashLib {

    // -------------------------------------------------------------------------
    // Type strings — authoritative definitions
    //
    // Rules:
    //   - Referenced structs are appended alphabetically after the primary type.
    //   - Field order must exactly match the struct definition in Types.sol.
    //   - Do not abbreviate. Do not reorder. Do not inline referenced types.
    // -------------------------------------------------------------------------

    bytes32 internal constant CONSTRAINTS_TYPEHASH = keccak256(
        "Constraints(uint256 maxSpendPerPeriod,uint256 periodDuration,"
        "uint256 minReturnBps,"
        "address[] allowedAdapters,address[] allowedTokensIn,address[] allowedTokensOut)"
    );

    bytes32 internal constant CAPABILITY_TYPEHASH = keccak256(
        "Capability(address issuer,address grantee,bytes32 scope,uint256 expiry,bytes32 nonce,"
        "Constraints constraints,bytes32 parentCapabilityHash,uint8 delegationDepth)"
        "Constraints(uint256 maxSpendPerPeriod,uint256 periodDuration,"
        "uint256 minReturnBps,"
        "address[] allowedAdapters,address[] allowedTokensIn,address[] allowedTokensOut)"
    );

    bytes32 internal constant INTENT_TYPEHASH = keccak256(
        "Intent(bytes32 positionCommitment,bytes32 capabilityHash,address adapter,"
        "bytes adapterData,uint256 minReturn,uint256 deadline,bytes32 nonce,"
        "address outputToken,address returnTo,address submitter,uint16 solverFeeBps)"
    );

    bytes32 internal constant ENVELOPE_TYPEHASH = keccak256(
        "Envelope(bytes32 positionCommitment,bytes32 conditionsHash,bytes32 intentCommitment,"
        "bytes32 capabilityHash,uint256 expiry,uint16 keeperRewardBps,uint128 minKeeperRewardWei)"
    );

    // -------------------------------------------------------------------------
    // Hashing functions
    // -------------------------------------------------------------------------

    function hashConstraints(Types.Constraints memory c) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            CONSTRAINTS_TYPEHASH,
            c.maxSpendPerPeriod,
            c.periodDuration,
            c.minReturnBps,
            _hashAddressArray(c.allowedAdapters),
            _hashAddressArray(c.allowedTokensIn),
            _hashAddressArray(c.allowedTokensOut)
        ));
    }

    /// @dev EIP-712 encoding of address[]: each element padded to 32 bytes, then keccak256.
    ///
    /// EIP-712 spec: "The array values are encoded as the keccak256 hash of the concatenated
    /// encodeData of their contents" where enc(address) = 32-byte left-zero-padded address.
    ///
    /// abi.encodePacked(address[]) is WRONG — packs addresses as 20 bytes each.
    /// abi.encode(address[]) is WRONG — includes a dynamic-array offset+length header.
    ///
    /// Correct approach: convert each address to bytes32 (left-zero-padded), build a
    /// bytes32[] and abi.encodePacked — which emits exactly 32 bytes per element with no
    /// header, matching what EIP-712 requires.
    function _hashAddressArray(address[] memory arr) private pure returns (bytes32) {
        uint256 len = arr.length;
        if (len == 0) return keccak256("");
        bytes32[] memory padded = new bytes32[](len);
        for (uint256 i = 0; i < len; i++) {
            padded[i] = bytes32(uint256(uint160(arr[i])));
        }
        return keccak256(abi.encodePacked(padded));
    }

    function hashCapability(Types.Capability memory cap) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            CAPABILITY_TYPEHASH,
            cap.issuer,
            cap.grantee,
            cap.scope,
            cap.expiry,
            cap.nonce,
            hashConstraints(cap.constraints),
            cap.parentCapabilityHash,
            cap.delegationDepth
        ));
    }

    function hashIntent(Types.Intent memory intent) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            INTENT_TYPEHASH,
            intent.positionCommitment,
            intent.capabilityHash,
            intent.adapter,
            keccak256(intent.adapterData),
            intent.minReturn,
            intent.deadline,
            intent.nonce,
            intent.outputToken,
            intent.returnTo,
            intent.submitter,
            intent.solverFeeBps
        ));
    }

    function hashEnvelope(Types.Envelope memory env) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            ENVELOPE_TYPEHASH,
            env.positionCommitment,
            env.conditionsHash,
            env.intentCommitment,
            env.capabilityHash,
            env.expiry,
            env.keeperRewardBps,
            env.minKeeperRewardWei
        ));
    }
}
