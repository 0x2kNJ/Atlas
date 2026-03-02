// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Types} from "./Types.sol";

/// @title SingletonVault
/// @notice Shared custody contract tracking user positions as hash commitments.
///
/// Key properties:
///   - No per-user accounts or contracts.
///   - Positions stored as keccak256(abi.encode(Position)) — not balances[user].
///   - Fee-on-transfer tokens handled correctly: commitment uses actual received amount.
///   - Emergency withdrawal available directly by position owner when paused.
///   - Token allowlist prevents dangerous tokens (rebasing, upgradeable, honeypots).
///   - Kernel and EnvelopeRegistry are the only contracts that can modify position state.

contract SingletonVault is Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    mapping(bytes32 positionHash => bool exists)      public positions;
    mapping(bytes32 positionHash => bool locked)      public encumbered;
    mapping(address token => bool allowed)            public tokenAllowlist;

    address public kernel;
    address public envelopeRegistry;

    /// @notice When false, only allowlisted tokens can be deposited.
    ///         Set to true only for testnets or explicit open deployments.
    bool public allowlistEnabled;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event PositionCreated(bytes32 indexed positionHash, address indexed asset, uint256 amount, address indexed owner);
    event PositionSpent(bytes32 indexed positionHash);
    event PositionEncumbered(bytes32 indexed positionHash);
    event PositionUnencumbered(bytes32 indexed positionHash);
    event EmergencyWithdraw(bytes32 indexed positionHash, address indexed owner, address to);
    event TokenAllowlisted(address indexed token, bool allowed);
    event KernelSet(address indexed kernel);
    event EnvelopeRegistrySet(address indexed registry);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error OnlyKernel();
    error OnlyEnvelopeRegistry();
    error PositionNotFound();
    error PositionAlreadyExists();
    error PositionIsEncumbered();
    error NotPositionOwner();
    error CommitmentMismatch();
    error AlreadyEncumbered();
    error TokenNotAllowlisted();
    error ZeroAmount();
    error ZeroAddress();
    error EmergencyWithdrawOnlyWhenPaused();

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyKernel() {
        if (msg.sender != kernel) revert OnlyKernel();
        _;
    }

    modifier onlyEnvelopeRegistry() {
        if (msg.sender != envelopeRegistry) revert OnlyEnvelopeRegistry();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _owner, bool _allowlistEnabled) Ownable(_owner) {
        allowlistEnabled = _allowlistEnabled;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    function setKernel(address _kernel) external onlyOwner {
        if (_kernel == address(0)) revert ZeroAddress();
        kernel = _kernel;
        emit KernelSet(_kernel);
    }

    function setEnvelopeRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert ZeroAddress();
        envelopeRegistry = _registry;
        emit EnvelopeRegistrySet(_registry);
    }

    function setTokenAllowlist(address token, bool allowed) external onlyOwner {
        tokenAllowlist[token] = allowed;
        emit TokenAllowlisted(token, allowed);
    }

    function setAllowlistEnabled(bool enabled) external onlyOwner {
        allowlistEnabled = enabled;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // User: deposit
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deposit tokens and create a position commitment.
    ///
    /// Fee-on-transfer safety:
    ///   The commitment is created for the ACTUAL amount received by the vault,
    ///   not the `amount` parameter. For standard tokens these are equal.
    ///   For fee-on-transfer tokens the commitment reflects what the vault truly holds.
    ///
    /// @param asset   ERC-20 token to deposit (must be allowlisted if allowlist enabled).
    /// @param amount  Token amount to transfer (pre-approval required).
    /// @param salt    User-chosen entropy — prevents commitment collision.
    ///                Recommended: keccak256(abi.encode(block.timestamp, msg.sender, randomNonce)).
    /// @return positionHash The commitment stored in the vault.
    function deposit(
        address asset,
        uint256 amount,
        bytes32 salt
    ) external whenNotPaused returns (bytes32 positionHash) {
        if (asset == address(0)) revert ZeroAddress();
        if (allowlistEnabled && !tokenAllowlist[asset]) revert TokenNotAllowlisted();
        if (amount == 0) revert ZeroAmount();

        // Measure actual received amount to handle fee-on-transfer tokens.
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualAmount = IERC20(asset).balanceOf(address(this)) - balanceBefore;

        if (actualAmount == 0) revert ZeroAmount();

        Types.Position memory pos = Types.Position({
            owner:  msg.sender,
            asset:  asset,
            amount: actualAmount,   // commitment uses actual received amount
            salt:   salt
        });

        positionHash = keccak256(abi.encode(pos));
        if (positions[positionHash]) revert PositionAlreadyExists();

        positions[positionHash] = true;
        emit PositionCreated(positionHash, asset, actualAmount, msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // User: withdraw
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Withdraw by revealing the position preimage. Normal path (vault not paused).
    function withdraw(Types.Position calldata position, address to) external whenNotPaused {
        bytes32 positionHash = keccak256(abi.encode(position));

        if (!positions[positionHash])        revert PositionNotFound();
        if (encumbered[positionHash])        revert PositionIsEncumbered();
        if (position.owner != msg.sender)    revert NotPositionOwner();

        positions[positionHash] = false;
        IERC20(position.asset).safeTransfer(to, position.amount);

        emit PositionSpent(positionHash);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // User: emergency withdrawal (only when paused)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emergency withdrawal bypassing kernel authorization. Only callable when vault is paused.
    ///
    /// When to use:
    ///   If a critical vulnerability is discovered in the kernel or adapters, the vault is paused
    ///   and users can withdraw directly using only their position preimage — no kernel required.
    ///   Encumbered positions (locked by envelopes) CAN be force-withdrawn in emergency.
    ///   The envelope system is bypassed by design — user funds always take priority.
    ///
    /// @param position  Full Position preimage — must hash to an existing commitment owned by caller.
    /// @param to        Recipient address.
    function emergencyWithdraw(Types.Position calldata position, address to) external whenPaused {
        bytes32 positionHash = keccak256(abi.encode(position));

        if (!positions[positionHash])     revert PositionNotFound();
        if (position.owner != msg.sender) revert NotPositionOwner();

        // Intentionally ignores encumbrance — emergency takes priority over envelope state.
        positions[positionHash] = false;
        if (encumbered[positionHash]) {
            encumbered[positionHash] = false;
        }

        IERC20(position.asset).safeTransfer(to, position.amount);

        emit EmergencyWithdraw(positionHash, msg.sender, to);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Kernel: release
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Spend a position commitment and send assets to recipient. Only callable by kernel.
    function release(
        bytes32 positionHash,
        Types.Position calldata position,
        address to
    ) external onlyKernel whenNotPaused {
        // L-2: guard against address(0) recipient — SafeERC20.safeTransfer allows this on many
        // tokens and would silently burn the position's assets.
        if (to == address(0)) revert ZeroAddress();
        if (!positions[positionHash])                        revert PositionNotFound();
        if (encumbered[positionHash])                        revert PositionIsEncumbered();
        if (keccak256(abi.encode(position)) != positionHash) revert CommitmentMismatch();

        positions[positionHash] = false;
        IERC20(position.asset).safeTransfer(to, position.amount);

        emit PositionSpent(positionHash);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Kernel: depositFor
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Accept output tokens from kernel and create a new position commitment.
    ///
    /// Fee-on-transfer safety:
    ///   Uses actual received amount, same as deposit(). The kernel passes the amount
    ///   it received from the adapter — if the output token is fee-on-transfer, the
    ///   commitment will reflect what the vault actually holds.
    ///
    function depositFor(
        address owner,
        address asset,
        uint256 amount,
        bytes32 salt
    ) external onlyKernel whenNotPaused returns (bytes32 positionHash) {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualAmount = IERC20(asset).balanceOf(address(this)) - balanceBefore;

        if (actualAmount == 0) revert ZeroAmount();

        Types.Position memory pos = Types.Position({
            owner:  owner,
            asset:  asset,
            amount: actualAmount,
            salt:   salt
        });

        positionHash = keccak256(abi.encode(pos));
        if (positions[positionHash]) revert PositionAlreadyExists();

        positions[positionHash] = true;
        emit PositionCreated(positionHash, asset, actualAmount, owner);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // EnvelopeRegistry: encumber / unencumber
    // ─────────────────────────────────────────────────────────────────────────

    function encumber(bytes32 positionHash) external onlyEnvelopeRegistry {
        if (!positions[positionHash]) revert PositionNotFound();
        if (encumbered[positionHash]) revert AlreadyEncumbered();
        encumbered[positionHash] = true;
        emit PositionEncumbered(positionHash);
    }

    function unencumber(bytes32 positionHash) external onlyEnvelopeRegistry {
        encumbered[positionHash] = false;
        emit PositionUnencumbered(positionHash);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────────────────────────

    function positionExists(bytes32 positionHash) external view returns (bool) {
        return positions[positionHash];
    }

    function isEncumbered(bytes32 positionHash) external view returns (bool) {
        return encumbered[positionHash];
    }

    function computePositionHash(Types.Position calldata position) external pure returns (bytes32) {
        return keccak256(abi.encode(position));
    }
}
