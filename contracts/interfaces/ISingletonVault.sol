// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "../Types.sol";

/// @title ISingletonVault
/// @notice Interface for the SingletonVault contract.
interface ISingletonVault {

    // ── User ─────────────────────────────────────────────────────────────────

    function deposit(address asset, uint256 amount, bytes32 salt)
        external returns (bytes32 positionHash);

    function withdraw(Types.Position calldata position, address to) external;

    // ── Kernel ───────────────────────────────────────────────────────────────

    function release(bytes32 positionHash, Types.Position calldata position, address to)
        external;

    function depositFor(address owner, address asset, uint256 amount, bytes32 salt)
        external returns (bytes32 positionHash);

    // ── Envelope registry ────────────────────────────────────────────────────

    function encumber(bytes32 positionHash) external;

    function unencumber(bytes32 positionHash) external;

    // ── View ─────────────────────────────────────────────────────────────────

    function positionExists(bytes32 positionHash) external view returns (bool);

    function isEncumbered(bytes32 positionHash) external view returns (bool);

    function computePositionHash(Types.Position calldata position)
        external pure returns (bytes32);
}
