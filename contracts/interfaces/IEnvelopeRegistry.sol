// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "../Types.sol";

/// @title IEnvelopeRegistry
/// @notice Interface for the EnvelopeRegistry contract.
interface IEnvelopeRegistry {

    /// @param position  Position preimage for on-chain ownership verification (L-3).
    function register(
        Types.Envelope calldata envelope,
        Types.Capability calldata capability,
        bytes calldata capSig,
        Types.Position calldata position
    ) external returns (bytes32 envelopeHash);

    function trigger(
        bytes32 envelopeHash,
        Types.Conditions calldata conditions,
        Types.Position calldata position,
        Types.Intent calldata intent,
        Types.Capability calldata capability,
        bytes calldata capSig,
        bytes calldata intentSig
    ) external;

    function cancel(bytes32 envelopeHash) external;

    function expire(bytes32 envelopeHash) external;

    function isActive(bytes32 envelopeHash) external view returns (bool);
}
