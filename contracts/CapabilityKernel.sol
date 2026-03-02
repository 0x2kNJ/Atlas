// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Types} from "./Types.sol";
import {HashLib} from "./HashLib.sol";
import {SingletonVault} from "./SingletonVault.sol";
import {IAdapter} from "./interfaces/IAdapter.sol";
import {IReceiptAccumulator} from "./interfaces/IReceiptAccumulator.sol";

/// @title CapabilityKernel
/// @notice Central verifier and execution coordinator for the Stateless Agent Protocol.
///
/// Verification order in executeIntent (fail-fast):
///   0.  Solver whitelist (Phase 1 MEV protection — Decision 7)
///   1.  Capability issuer signature
///   2.  Intent grantee signature
///   3.  Intent references correct capability hash
///   4.  Scope is vault.spend
///   5.  Capability not expired
///   6.  Capability nonce not revoked
///   7.  Delegation depth == 0 (Phase 1 guard)
///   8.  Intent deadline not passed
///   9.  Per-intent submitter check (if intent.submitter != address(0))
///   10. Solver fee within bounds
///   11. Nullifier not spent
///   12. Position preimage matches commitment
///   13. Position owner matches capability issuer
///   14. Position exists and not encumbered
///   15. Adapter registered and allowed by constraints
///   16. Token constraints
///   17. Adapter parameter validation
///   18. Period spending limit
///   → Nullifier marked spent → assets released → adapter executes → solver fee → output committed
///
/// Every rejection emits IntentRejected before reverting (Decision 9).
/// This event is the canonical input for the ZK compliance circuit (Phase 2, Circuit 1).

contract CapabilityKernel is EIP712, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    bytes32 public constant VAULT_SPEND_SCOPE     = keccak256("vault.spend");
    bytes32 public constant ENVELOPE_MANAGE_SCOPE = keccak256("envelope.manage");

    /// @notice Maximum solver fee: 1% of gross output.
    uint16 public constant MAX_SOLVER_FEE_BPS = 100;

    // ─────────────────────────────────────────────────────────────────────────
    // EIP-712 type hashes
    // ─────────────────────────────────────────────────────────────────────────

    // Type hashes are defined in HashLib — do not redefine here.
    // Importing them as constants for external visibility (SDK use).
    bytes32 public constant CONSTRAINTS_TYPEHASH = HashLib.CONSTRAINTS_TYPEHASH;
    bytes32 public constant CAPABILITY_TYPEHASH   = HashLib.CAPABILITY_TYPEHASH;
    bytes32 public constant INTENT_TYPEHASH       = HashLib.INTENT_TYPEHASH;

    // ─────────────────────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────────────────────

    SingletonVault public immutable vault;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    mapping(bytes32 nullifier => bool spent)                                           public spentNullifiers;
    mapping(address issuer => mapping(bytes32 nonce => bool revoked))                  public revokedNonces;
    mapping(address adapter => bool registered)                                        public adapterRegistry;
    mapping(bytes32 capHash => mapping(uint256 periodIndex => uint256 spent))          public periodSpending;
    /// @notice Addresses approved to call executeIntent. Controlled by owner (Decision 7).
    ///         Phase 3+: owner opens this to permissionless solvers by removing the guard.
    mapping(address solver => bool approved)                                           public approvedSolvers;

    /// @notice Optional receipt accumulator. When set, every successful executeIntent
    ///         appends a receipt to the accumulator, anchoring Circuit 1 proofs.
    ///         Set to address(0) to disable (default). Never affects execution logic.
    IReceiptAccumulator public receiptAccumulator;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event ReceiptAccumulatorSet(address indexed accumulator);

    event IntentExecuted(
        bytes32 indexed nullifier,
        bytes32 indexed positionIn,
        bytes32 indexed positionOut,
        address solver,
        address adapter,
        uint256 amountIn,
        uint256 amountOut,
        uint256 solverFee
    );
    /// @notice Emitted before every revert in executeIntent (Decision 9).
    ///         The ZK compliance circuit consumes this event to prove the agent's enforcement history.
    ///         `spentThisPeriod` and `periodLimit` are non-zero only for PERIOD_LIMIT_EXCEEDED.
    event IntentRejected(
        bytes32 indexed capabilityHash,
        address indexed grantee,
        bytes32 reason,
        uint256 spentThisPeriod,
        uint256 periodLimit
    );
    event CapabilityRevoked(address indexed issuer, bytes32 indexed nonce);
    event AdapterRegistered(address indexed adapter);
    event AdapterRemoved(address indexed adapter);
    event SolverApproved(address indexed solver);
    event SolverRemoved(address indexed solver);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error SolverNotApproved();
    error InvalidCapabilitySig();
    error InvalidIntentSig();
    error CapabilityHashMismatch();
    error WrongScope();
    error CapabilityExpired();
    error CapabilityNonceRevoked();
    error DelegationDepthNotSupported();
    error IntentExpired();
    error UnauthorizedSubmitter();
    error SolverFeeTooHigh();
    error NullifierSpent();
    error CommitmentMismatch();
    error OwnerMismatch();
    error PositionEncumberedError();
    error AdapterNotRegistered();
    error AdapterNotAllowed();
    error TokenInNotAllowed();
    error TokenOutNotAllowed();
    error PeriodLimitExceeded();
    error InsufficientOutput();
    error AdapterValidationFailed(string reason);
    error MinReturnBpsViolation(uint256 amountIn, uint256 amountOut, uint256 minReturnBps);

    // ─────────────────────────────────────────────────────────────────────────
    // IntentRejected reason codes — keccak256 of short error key strings.
    // These are compile-time constants; no storage cost.
    // The ZK circuit identifies rejection reasons by these hashes.
    // ─────────────────────────────────────────────────────────────────────────

    bytes32 public constant REASON_SOLVER_NOT_APPROVED    = keccak256("SOLVER_NOT_APPROVED");
    bytes32 public constant REASON_INVALID_CAPABILITY_SIG = keccak256("INVALID_CAPABILITY_SIG");
    bytes32 public constant REASON_INVALID_INTENT_SIG     = keccak256("INVALID_INTENT_SIG");
    bytes32 public constant REASON_CAP_HASH_MISMATCH      = keccak256("CAP_HASH_MISMATCH");
    bytes32 public constant REASON_WRONG_SCOPE            = keccak256("WRONG_SCOPE");
    bytes32 public constant REASON_CAP_EXPIRED            = keccak256("CAP_EXPIRED");
    bytes32 public constant REASON_CAP_REVOKED            = keccak256("CAP_REVOKED");
    bytes32 public constant REASON_DELEGATION_DEPTH       = keccak256("DELEGATION_DEPTH");
    bytes32 public constant REASON_INTENT_EXPIRED         = keccak256("INTENT_EXPIRED");
    bytes32 public constant REASON_UNAUTHORIZED_SUBMITTER = keccak256("UNAUTHORIZED_SUBMITTER");
    bytes32 public constant REASON_SOLVER_FEE_TOO_HIGH    = keccak256("SOLVER_FEE_TOO_HIGH");
    bytes32 public constant REASON_NULLIFIER_SPENT        = keccak256("NULLIFIER_SPENT");
    bytes32 public constant REASON_COMMITMENT_MISMATCH    = keccak256("COMMITMENT_MISMATCH");
    bytes32 public constant REASON_OWNER_MISMATCH         = keccak256("OWNER_MISMATCH");
    bytes32 public constant REASON_POSITION_ENCUMBERED    = keccak256("POSITION_ENCUMBERED");
    bytes32 public constant REASON_ADAPTER_NOT_REGISTERED = keccak256("ADAPTER_NOT_REGISTERED");
    bytes32 public constant REASON_ADAPTER_NOT_ALLOWED    = keccak256("ADAPTER_NOT_ALLOWED");
    bytes32 public constant REASON_TOKEN_IN_NOT_ALLOWED   = keccak256("TOKEN_IN_NOT_ALLOWED");
    bytes32 public constant REASON_TOKEN_OUT_NOT_ALLOWED  = keccak256("TOKEN_OUT_NOT_ALLOWED");
    bytes32 public constant REASON_PERIOD_LIMIT_EXCEEDED  = keccak256("PERIOD_LIMIT_EXCEEDED");
    bytes32 public constant REASON_INSUFFICIENT_OUTPUT    = keccak256("INSUFFICIENT_OUTPUT");
    bytes32 public constant REASON_ADAPTER_VALIDATION     = keccak256("ADAPTER_VALIDATION_FAILED");
    bytes32 public constant REASON_MIN_RETURN_BPS         = keccak256("MIN_RETURN_BPS_VIOLATION");

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        address _vault,
        address _owner
    ) EIP712("CapabilityKernel", "1") Ownable(_owner) {
        vault = SingletonVault(_vault);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    function pause() external onlyOwner   { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerAdapter(address adapter) external onlyOwner {
        adapterRegistry[adapter] = true;
        emit AdapterRegistered(adapter);
    }

    function removeAdapter(address adapter) external onlyOwner {
        adapterRegistry[adapter] = false;
        emit AdapterRemoved(adapter);
    }

    /// @notice Approve or revoke a solver address (Decision 7).
    ///         Phase 1: only whitelisted solvers may call executeIntent.
    ///         Phase 3+: open to permissionless solvers — this guard is removed or all-allowed.
    function setReceiptAccumulator(address _accumulator) external onlyOwner {
        receiptAccumulator = IReceiptAccumulator(_accumulator);
        emit ReceiptAccumulatorSet(_accumulator);
    }

    function setSolver(address solver, bool approved) external onlyOwner {
        approvedSolvers[solver] = approved;
        if (approved) emit SolverApproved(solver);
        else          emit SolverRemoved(solver);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // User: revoke capability
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Revoke a capability by nonce. One transaction. No guardian. No timelock.
    /// @dev Any pending intent referencing this nonce will fail at step 6 of verification.
    function revokeCapability(bytes32 nonce) external {
        revokedNonces[msg.sender][nonce] = true;
        emit CapabilityRevoked(msg.sender, nonce);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core: executeIntent
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Verify and execute a capability-authorized intent.
    ///
    /// MEV protection:
    ///   If intent.submitter != address(0), only that address can call this function.
    ///   Phase 1: set intent.submitter to the protocol's solver address.
    ///   Phase 3+: set to address(0) to open to any solver.
    ///
    /// Solver fee:
    ///   msg.sender receives (amountOut * intent.solverFeeBps / 10000) of output token.
    ///   Remaining output goes into the vault as a new position commitment.
    ///   The fee comes from gross output — minReturn is the floor before fee deduction.
    ///
    /// @param position    Revealed Position preimage.
    /// @param capability  Off-chain capability token.
    /// @param intent      Off-chain execution instruction.
    /// @param capSig      ECDSA signature over capability by capability.issuer.
    /// @param intentSig   ECDSA signature over intent by capability.grantee.
    /// @return receiptHash  keccak256(nullifier, positionIn, positionOut).
    function executeIntent(
        Types.Position calldata position,
        Types.Capability calldata capability,
        Types.Intent calldata intent,
        bytes calldata capSig,
        bytes calldata intentSig
    ) external nonReentrant whenNotPaused returns (bytes32 receiptHash) {

        // Compute capHash early — required for IntentRejected events on every rejection path.
        bytes32 capHash = _hashCapability(capability);

        // ── 0. Solver whitelist (Decision 7) ─────────────────────────────────
        //    Only approved solvers may execute intents in Phase 1.
        //    Phase 3+: this guard is lifted; open solver market with stake/slashing.
        if (!approvedSolvers[msg.sender]) {
            emit IntentRejected(capHash, capability.grantee, REASON_SOLVER_NOT_APPROVED, 0, 0);
            revert SolverNotApproved();
        }

        // ── 1. Capability signature ──────────────────────────────────────────
        if (_hashTypedDataV4(capHash).recover(capSig) != capability.issuer) {
            emit IntentRejected(capHash, capability.grantee, REASON_INVALID_CAPABILITY_SIG, 0, 0);
            revert InvalidCapabilitySig();
        }

        // ── 2. Intent signature ──────────────────────────────────────────────
        bytes32 intentHash = _hashIntent(intent);
        if (_hashTypedDataV4(intentHash).recover(intentSig) != capability.grantee) {
            emit IntentRejected(capHash, capability.grantee, REASON_INVALID_INTENT_SIG, 0, 0);
            revert InvalidIntentSig();
        }

        // ── 3. Intent must reference this capability ─────────────────────────
        if (intent.capabilityHash != capHash) {
            emit IntentRejected(capHash, capability.grantee, REASON_CAP_HASH_MISMATCH, 0, 0);
            revert CapabilityHashMismatch();
        }

        // ── 4. Scope ─────────────────────────────────────────────────────────
        if (capability.scope != VAULT_SPEND_SCOPE) {
            emit IntentRejected(capHash, capability.grantee, REASON_WRONG_SCOPE, 0, 0);
            revert WrongScope();
        }

        // ── 5. Capability expiry ─────────────────────────────────────────────
        if (capability.expiry <= block.timestamp) {
            emit IntentRejected(capHash, capability.grantee, REASON_CAP_EXPIRED, 0, 0);
            revert CapabilityExpired();
        }

        // ── 6. Capability revocation ─────────────────────────────────────────
        if (revokedNonces[capability.issuer][capability.nonce]) {
            emit IntentRejected(capHash, capability.grantee, REASON_CAP_REVOKED, 0, 0);
            revert CapabilityNonceRevoked();
        }

        // ── 7. Delegation depth guard (Phase 1: root delegation only) ────────
        if (capability.delegationDepth != 0) {
            emit IntentRejected(capHash, capability.grantee, REASON_DELEGATION_DEPTH, 0, 0);
            revert DelegationDepthNotSupported();
        }

        // ── 8. Intent deadline ───────────────────────────────────────────────
        if (intent.deadline <= block.timestamp) {
            emit IntentRejected(capHash, capability.grantee, REASON_INTENT_EXPIRED, 0, 0);
            revert IntentExpired();
        }

        // ── 9. Per-intent submitter check (MEV protection) ───────────────────
        //    Protocol-level solver whitelist (step 0) is the primary gate.
        //    This per-intent check allows further restriction: lock an intent to
        //    one specific solver address. address(0) = any whitelisted solver.
        if (intent.submitter != address(0) && intent.submitter != msg.sender) {
            emit IntentRejected(capHash, capability.grantee, REASON_UNAUTHORIZED_SUBMITTER, 0, 0);
            revert UnauthorizedSubmitter();
        }

        // ── 10. Solver fee bounds ────────────────────────────────────────────
        if (intent.solverFeeBps > MAX_SOLVER_FEE_BPS) {
            emit IntentRejected(capHash, capability.grantee, REASON_SOLVER_FEE_TOO_HIGH, 0, 0);
            revert SolverFeeTooHigh();
        }

        // ── 11. Nullifier ────────────────────────────────────────────────────
        bytes32 nullifier = keccak256(abi.encode(intent.nonce, intent.positionCommitment));
        if (spentNullifiers[nullifier]) {
            emit IntentRejected(capHash, capability.grantee, REASON_NULLIFIER_SPENT, 0, 0);
            revert NullifierSpent();
        }

        // ── 12. Commitment verification ──────────────────────────────────────
        if (keccak256(abi.encode(position)) != intent.positionCommitment) {
            emit IntentRejected(capHash, capability.grantee, REASON_COMMITMENT_MISMATCH, 0, 0);
            revert CommitmentMismatch();
        }

        // ── 13. Owner matches capability issuer ──────────────────────────────
        if (position.owner != capability.issuer) {
            emit IntentRejected(capHash, capability.grantee, REASON_OWNER_MISMATCH, 0, 0);
            revert OwnerMismatch();
        }

        // ── 14. Position state ───────────────────────────────────────────────
        if (!vault.positionExists(intent.positionCommitment)) {
            emit IntentRejected(capHash, capability.grantee, REASON_COMMITMENT_MISMATCH, 0, 0);
            revert CommitmentMismatch();
        }
        if (vault.isEncumbered(intent.positionCommitment)) {
            emit IntentRejected(capHash, capability.grantee, REASON_POSITION_ENCUMBERED, 0, 0);
            revert PositionEncumberedError();
        }

        // ── 15. Adapter ──────────────────────────────────────────────────────
        if (!adapterRegistry[intent.adapter]) {
            emit IntentRejected(capHash, capability.grantee, REASON_ADAPTER_NOT_REGISTERED, 0, 0);
            revert AdapterNotRegistered();
        }
        _checkAdapterAllowedOrReject(capHash, capability.grantee, intent.adapter, capability.constraints);

        // ── 16. Token constraints ────────────────────────────────────────────
        _checkTokenConstraintsOrReject(capHash, capability.grantee, position.asset, intent.outputToken, capability.constraints);

        // ── 17. Adapter parameter validation ────────────────────────────────
        (bool valid, string memory reason) = IAdapter(intent.adapter).validate(
            position.asset, intent.outputToken, position.amount, intent.adapterData
        );
        if (!valid) {
            emit IntentRejected(capHash, capability.grantee, REASON_ADAPTER_VALIDATION, 0, 0);
            revert AdapterValidationFailed(reason);
        }

        // ── 18. Period spending ──────────────────────────────────────────────
        if (capability.constraints.maxSpendPerPeriod > 0 && capability.constraints.periodDuration > 0) {
            uint256 periodIndex  = block.timestamp / capability.constraints.periodDuration;
            uint256 currentSpend = periodSpending[capHash][periodIndex];
            if (currentSpend + position.amount > capability.constraints.maxSpendPerPeriod) {
                emit IntentRejected(
                    capHash, capability.grantee, REASON_PERIOD_LIMIT_EXCEEDED,
                    currentSpend, capability.constraints.maxSpendPerPeriod
                );
                revert PeriodLimitExceeded();
            }
            periodSpending[capHash][periodIndex] = currentSpend + position.amount;
        }

        // ── State changes before external calls ─────────────────────────────
        spentNullifiers[nullifier] = true;

        // ── Release assets from vault to kernel ──────────────────────────────
        vault.release(intent.positionCommitment, position, address(this));

        // ── Execute via adapter ───────────────────────────────────────────────
        IERC20(position.asset).forceApprove(intent.adapter, position.amount);

        uint256 grossAmountOut = IAdapter(intent.adapter).execute(
            position.asset,
            intent.outputToken,
            position.amount,
            intent.minReturn,
            intent.adapterData
        );

        IERC20(position.asset).forceApprove(intent.adapter, 0);

        // Gross output floor.
        if (grossAmountOut < intent.minReturn) {
            emit IntentRejected(capHash, capability.grantee, REASON_INSUFFICIENT_OUTPUT, 0, 0);
            revert InsufficientOutput();
        }

        // Capability-level slippage floor (only when minReturnBps > 0).
        if (capability.constraints.minReturnBps > 0) {
            uint256 floor = (position.amount * capability.constraints.minReturnBps) / 10_000;
            if (grossAmountOut < floor) {
                emit IntentRejected(capHash, capability.grantee, REASON_MIN_RETURN_BPS, 0, 0);
                revert MinReturnBpsViolation(position.amount, grossAmountOut, capability.constraints.minReturnBps);
            }
        }

        // ── Solver fee deduction ─────────────────────────────────────────────
        uint256 solverFee    = (grossAmountOut * intent.solverFeeBps) / 10_000;
        uint256 netAmountOut = grossAmountOut - solverFee;

        if (solverFee > 0) {
            IERC20(intent.outputToken).safeTransfer(msg.sender, solverFee);
        }

        // ── Commit net output back to vault ──────────────────────────────────
        //
        // M-3: honour intent.returnTo when set.
        //
        // returnTo lets an agent direct output to a different vault account than the
        // input position owner — for example, routing swap proceeds into a dedicated
        // yield-holding account or a sub-agent address.
        //
        // If returnTo == address(0) the output goes back to position.owner (default,
        // preserving backwards-compatible behaviour).
        //
        // Security note: returnTo is part of the EIP-712 intent hash so the grantee
        // explicitly signs over the destination.  A solver cannot redirect output without
        // invalidating the intent signature (step 2 of verification).
        address outputOwner = (intent.returnTo != address(0)) ? intent.returnTo : position.owner;
        bytes32 outputSalt  = keccak256(abi.encode(nullifier, "output"));
        IERC20(intent.outputToken).forceApprove(address(vault), netAmountOut);

        bytes32 newPositionHash = vault.depositFor(
            outputOwner,
            intent.outputToken,
            netAmountOut,
            outputSalt
        );

        // ── Receipt ──────────────────────────────────────────────────────────
        receiptHash = keccak256(abi.encode(nullifier, intent.positionCommitment, newPositionHash));

        emit IntentExecuted(
            nullifier,
            intent.positionCommitment,
            newPositionHash,
            msg.sender,
            intent.adapter,
            position.amount,
            grossAmountOut,
            solverFee
        );

        // ── Optional: accumulate receipt for Circuit 1 ────────────────────────
        // This call is the Phase 2 anchor. When receiptAccumulator is set, every
        // successful execution is committed to the rolling hash chain — enabling
        // Circuit 1 proofs with full anti-fabrication guarantees.
        // address(0) = accumulator not deployed (default Phase 1 behaviour unchanged).
        if (address(receiptAccumulator) != address(0)) {
            receiptAccumulator.accumulate(
                capHash,
                receiptHash,
                nullifier,
                intent.adapter,
                position.amount,
                grossAmountOut
            );
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────────────────────────

    function isSpent(bytes32 nullifier) external view returns (bool) {
        return spentNullifiers[nullifier];
    }

    function isRevoked(address issuer, bytes32 nonce) external view returns (bool) {
        return revokedNonces[issuer][nonce];
    }

    /// @notice Compute the EIP-712 signing digest for a Capability (for SDK use).
    function capabilityDigest(Types.Capability calldata cap) external view returns (bytes32) {
        return _hashTypedDataV4(_hashCapability(cap));
    }

    /// @notice Compute the EIP-712 signing digest for an Intent (for SDK use).
    function intentDigest(Types.Intent calldata intent) external view returns (bytes32) {
        return _hashTypedDataV4(_hashIntent(intent));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: EIP-712 hashing — delegates to HashLib (single source of truth)
    // ─────────────────────────────────────────────────────────────────────────

    function _hashCapability(Types.Capability memory cap) internal pure returns (bytes32) {
        return HashLib.hashCapability(cap);
    }

    function _hashIntent(Types.Intent memory intent) internal pure returns (bytes32) {
        return HashLib.hashIntent(intent);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: constraint enforcement
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Checks adapter allowlist; emits IntentRejected before reverting.
    function _checkAdapterAllowedOrReject(
        bytes32 capHash,
        address grantee,
        address adapter,
        Types.Constraints memory constraints
    ) internal {
        if (constraints.allowedAdapters.length == 0) return;
        for (uint256 i; i < constraints.allowedAdapters.length; ++i) {
            if (constraints.allowedAdapters[i] == adapter) return;
        }
        emit IntentRejected(capHash, grantee, REASON_ADAPTER_NOT_ALLOWED, 0, 0);
        revert AdapterNotAllowed();
    }

    /// @dev Checks token allowlists; emits IntentRejected before reverting.
    function _checkTokenConstraintsOrReject(
        bytes32 capHash,
        address grantee,
        address tokenIn,
        address tokenOut,
        Types.Constraints memory constraints
    ) internal {
        if (constraints.allowedTokensIn.length > 0) {
            bool found = false;
            for (uint256 i; i < constraints.allowedTokensIn.length; ++i) {
                if (constraints.allowedTokensIn[i] == tokenIn) { found = true; break; }
            }
            if (!found) {
                emit IntentRejected(capHash, grantee, REASON_TOKEN_IN_NOT_ALLOWED, 0, 0);
                revert TokenInNotAllowed();
            }
        }
        if (constraints.allowedTokensOut.length > 0) {
            bool found = false;
            for (uint256 i; i < constraints.allowedTokensOut.length; ++i) {
                if (constraints.allowedTokensOut[i] == tokenOut) { found = true; break; }
            }
            if (!found) {
                emit IntentRejected(capHash, grantee, REASON_TOKEN_OUT_NOT_ALLOWED, 0, 0);
                revert TokenOutNotAllowed();
            }
        }
    }
}
