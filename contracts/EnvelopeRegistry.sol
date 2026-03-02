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
import {CapabilityKernel} from "./CapabilityKernel.sol";

/// @dev Minimal Chainlink-compatible price feed interface.
interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

/// @title EnvelopeRegistry
/// @notice Stores pre-committed conditional execution instructions (envelopes).
///
/// An envelope decouples "when to act" from "what to do" and removes the requirement
/// for agent liveness at execution time. A stop-loss, liquidation trigger, or
/// rebalancing threshold can be registered once and executed permissionlessly by any
/// keeper when on-chain conditions are met — even if the AI agent is offline.
///
/// Lifecycle:
///   register()  — agent creates envelope, position becomes encumbered
///   trigger()   — keeper reveals conditions + intent preimages, executes if condition holds
///   cancel()    — issuer cancels envelope, position unencumbered
///   expire()    — anyone can clean up after expiry, position unencumbered
///
/// Security model:
///   - Conditions are committed as a hash at registration — keeper cannot manipulate them.
///   - The oracle price is read on-chain at trigger time — keeper cannot fake price data.
///   - The intent is committed as a hash — keeper executes exactly what the agent pre-authorized.
///   - Keeper reward is bounded by keeperRewardBps (max 500 = 5%).
///   - Capability and intent signatures are re-verified by CapabilityKernel during execution.

contract EnvelopeRegistry is EIP712, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // Type hashes are defined in HashLib — single source of truth shared with CapabilityKernel.
    bytes32 public constant CAPABILITY_TYPEHASH = HashLib.CAPABILITY_TYPEHASH;
    bytes32 public constant ENVELOPE_TYPEHASH   = HashLib.ENVELOPE_TYPEHASH;

    /// @notice Maximum keeper reward percentage: 5%.
    uint16  public constant MAX_KEEPER_REWARD_BPS = 500;

    /// @notice Maximum acceptable oracle staleness (seconds).
    uint256 public constant MAX_ORACLE_AGE = 3600;

    /// @notice Absolute minimum keeper reward to prevent unprofitable triggers on small positions.
    ///         Stored per-envelope in Envelope.minKeeperRewardWei.
    ///         Keeper receives: max(minKeeperRewardWei, outputAmount * keeperRewardBps / 10000).
    ///         Protocol-level floor (applies regardless of envelope setting).
    uint128 public protocolMinKeeperRewardWei;

    // ─────────────────────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────────────────────

    SingletonVault    public immutable vault;
    CapabilityKernel  public immutable kernel;

    // ─────────────────────────────────────────────────────────────────────────
    // Envelope state
    // ─────────────────────────────────────────────────────────────────────────

    enum EnvelopeStatus { None, Active, Triggered, Cancelled, Expired }

    struct EnvelopeRecord {
        Types.Envelope  envelope;
        address         issuer;      // capability.issuer — the only address that can cancel
        EnvelopeStatus  status;
    }

    mapping(bytes32 envelopeHash => EnvelopeRecord record) public envelopes;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event EnvelopeRegistered(
        bytes32 indexed envelopeHash,
        bytes32 indexed positionCommitment,
        address indexed issuer,
        uint256 expiry
    );
    event EnvelopeTriggered(
        bytes32 indexed envelopeHash,
        address indexed keeper,
        uint256 keeperReward
    );
    event EnvelopeCancelled(bytes32 indexed envelopeHash);
    event EnvelopeExpired(bytes32 indexed envelopeHash);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event ProtocolMinKeeperRewardUpdated(uint128 oldValue, uint128 newValue);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error EnvelopeNotFound();
    error EnvelopeNotActive();
    error NotIssuer();
    error EnvelopeAlreadyExists();
    error KeeperRewardTooHigh();
    error ConditionsMismatch();
    error IntentMismatch();
    error CapabilityHashMismatch();
    error ConditionNotMet();
    error OracleStale();
    error OracleInvalidAnswer();
    error InvalidCapabilitySig();
    error EnvelopeNotExpired();
    error RescueAmountZero();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        address _vault,
        address _kernel,
        address _owner,
        uint128 _protocolMinKeeperRewardWei
    ) EIP712("EnvelopeRegistry", "1") Ownable(_owner) {
        vault  = SingletonVault(_vault);
        kernel = CapabilityKernel(_kernel);
        protocolMinKeeperRewardWei = _protocolMinKeeperRewardWei;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    function pause() external onlyOwner   { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setProtocolMinKeeperRewardWei(uint128 minReward) external onlyOwner {
        emit ProtocolMinKeeperRewardUpdated(protocolMinKeeperRewardWei, minReward);
        protocolMinKeeperRewardWei = minReward;
    }

    /// @notice Rescue ERC-20 tokens that have been sent to this contract accidentally,
    ///         or dust left by failed/partial adapter calls (Decision 12).
    ///
    /// Only callable by the protocol owner. Not usable to drain active position assets —
    /// position funds live in the SingletonVault, not here. This contract temporarily
    /// holds output tokens during trigger() execution and should hold no balance at rest.
    /// Any non-zero balance at rest indicates a stuck or partial execution and warrants rescue.
    ///
    /// @param token   ERC-20 token to rescue.
    /// @param to      Recipient address (protocol multisig or affected user).
    /// @param amount  Amount to transfer.
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (amount == 0) revert RescueAmountZero();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Register
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Register a conditional execution envelope.
    ///
    /// The agent:
    ///   1. Pre-commits to Conditions (e.g. "ETH price < $1800").
    ///   2. Pre-commits to an Intent to execute when the condition is met.
    ///   3. Provides a Capability authorizing this envelope creation (scope: envelope.manage).
    ///   4. Reveals the Position preimage so the registry can verify ownership on-chain (L-3).
    ///   5. Calls register() — position becomes encumbered immediately.
    ///
    /// L-3 security note: without the position preimage, the registry can only verify that
    /// the position commitment exists — not that capability.issuer actually owns it.  An attacker
    /// with a valid envelope.manage capability could encumber any existing position, locking its
    /// owner out of normal execution until the envelope expires.  Revealing the preimage here
    /// lets the registry derive the commitment and verify ownership before encumbering.
    ///
    /// @param envelope    The envelope struct (conditions and intent stored as hashes).
    /// @param capability  Capability with scope envelope.manage, signed by the position owner.
    /// @param capSig      Issuer's EIP-712 signature over the capability.
    /// @param position    Position preimage whose commitment must match envelope.positionCommitment
    ///                    AND whose owner must match capability.issuer.
    function register(
        Types.Envelope calldata envelope,
        Types.Capability calldata capability,
        bytes calldata capSig,
        Types.Position calldata position
    ) external nonReentrant whenNotPaused returns (bytes32 envelopeHash) {

        // ── Validate envelope fields ─────────────────────────────────────────
        if (envelope.keeperRewardBps > MAX_KEEPER_REWARD_BPS) revert KeeperRewardTooHigh();
        if (envelope.expiry <= block.timestamp) revert EnvelopeNotActive();
        // minKeeperRewardWei must be at least the protocol floor.
        require(
            envelope.minKeeperRewardWei >= protocolMinKeeperRewardWei,
            "EnvelopeRegistry: keeper reward below protocol floor"
        );

        // ── Verify capability signature ──────────────────────────────────────
        bytes32 capHash = _hashCapability(capability);
        address capSigner = _hashTypedDataV4(capHash).recover(capSig);
        if (capSigner != capability.issuer) revert InvalidCapabilitySig();

        // ── Verify capability matches envelope ───────────────────────────────
        if (envelope.capabilityHash != capHash) revert CapabilityHashMismatch();

        // ── Verify scope ─────────────────────────────────────────────────────
        bytes32 requiredScope = keccak256("envelope.manage");
        require(capability.scope == requiredScope, "EnvelopeRegistry: wrong scope");

        // ── Verify capability not expired or revoked ─────────────────────────
        require(capability.expiry > block.timestamp, "EnvelopeRegistry: capability expired");
        require(
            !kernel.isRevoked(capability.issuer, capability.nonce),
            "EnvelopeRegistry: capability revoked"
        );

        // ── Verify position preimage and ownership (L-3) ─────────────────────
        //
        // Derive the commitment from the revealed preimage and cross-check it against
        // envelope.positionCommitment.  This ensures:
        //   (a) the position actually exists in the vault, and
        //   (b) the capability issuer is the position owner.
        //
        // Without this check an attacker with any valid envelope.manage capability could
        // supply an arbitrary positionCommitment they don't own, encumbering a victim's
        // position and blocking their access until the envelope expires.
        bytes32 derivedCommitment = keccak256(abi.encode(position));
        require(
            derivedCommitment == envelope.positionCommitment,
            "EnvelopeRegistry: position preimage mismatch"
        );
        require(
            position.owner == capability.issuer,
            "EnvelopeRegistry: position owner does not match capability issuer"
        );
        require(
            vault.positionExists(envelope.positionCommitment),
            "EnvelopeRegistry: position not found"
        );

        // ── Store envelope and encumber position ─────────────────────────────
        envelopeHash = HashLib.hashEnvelope(envelope);

        if (envelopes[envelopeHash].status != EnvelopeStatus.None) revert EnvelopeAlreadyExists();

        envelopes[envelopeHash] = EnvelopeRecord({
            envelope: envelope,
            issuer:   capability.issuer,
            status:   EnvelopeStatus.Active
        });

        vault.encumber(envelope.positionCommitment);

        emit EnvelopeRegistered(
            envelopeHash,
            envelope.positionCommitment,
            capability.issuer,
            envelope.expiry
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Trigger
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Trigger an envelope when conditions are met. Callable by any keeper.
    ///
    /// The keeper:
    ///   1. Reveals the Conditions preimage (verified against conditionsHash).
    ///   2. Reveals the Intent preimage (verified against intentCommitment).
    ///   3. The registry reads the oracle on-chain to confirm the condition currently holds.
    ///   4. The registry unencumbers the position and forwards execution to CapabilityKernel.
    ///   5. The keeper receives keeperRewardBps of the output position's amount.
    ///
    /// @param envelopeHash  Hash of the registered envelope.
    /// @param conditions    Revealed Conditions preimage.
    /// @param position      Revealed Position preimage (must match envelope.positionCommitment).
    /// @param intent        Revealed Intent preimage (must match envelope.intentCommitment).
    /// @param capability    Full Capability struct authorizing intent execution.
    /// @param capSig        Issuer's signature over the capability.
    /// @param intentSig     Grantee's signature over the intent.
    function trigger(
        bytes32 envelopeHash,
        Types.Conditions calldata conditions,
        Types.Position calldata position,
        Types.Intent calldata intent,
        Types.Capability calldata capability,
        bytes calldata capSig,
        bytes calldata intentSig
    ) external nonReentrant {

        EnvelopeRecord storage record = envelopes[envelopeHash];
        if (record.status == EnvelopeStatus.None)    revert EnvelopeNotFound();
        if (record.status != EnvelopeStatus.Active)  revert EnvelopeNotActive();
        if (record.envelope.expiry <= block.timestamp) {
            // Lazily expire.
            _expire(envelopeHash, record);
            return;
        }

        Types.Envelope memory env = record.envelope;

        // ── Verify conditions preimage ───────────────────────────────────────
        if (keccak256(abi.encode(conditions)) != env.conditionsHash) revert ConditionsMismatch();

        // ── Verify intent preimage ───────────────────────────────────────────
        if (keccak256(abi.encode(intent)) != env.intentCommitment) revert IntentMismatch();

        // ── Check oracle condition on-chain ──────────────────────────────────
        _assertConditionMet(conditions);

        // ── Mark triggered before external calls ────────────────────────────
        record.status = EnvelopeStatus.Triggered;

        // ── Unencumber so the kernel can release the position ────────────────
        vault.unencumber(env.positionCommitment);

        // ── Execute via kernel ───────────────────────────────────────────────
        // The kernel re-verifies all capability and intent signatures.
        // The kernel treats its msg.sender (this registry) as the solver and pays the
        // solver fee (intent.solverFeeBps of gross output) to address(this) in intent.outputToken.
        // We measure the balance delta to capture exactly what we received, then forward
        // the full amount to the actual keeper (msg.sender of this trigger() call).
        uint256 balanceBefore = IERC20(intent.outputToken).balanceOf(address(this));

        kernel.executeIntent(position, capability, intent, capSig, intentSig);

        uint256 keeperReward = IERC20(intent.outputToken).balanceOf(address(this)) - balanceBefore;
        if (keeperReward > 0) {
            IERC20(intent.outputToken).safeTransfer(msg.sender, keeperReward);
        }

        emit EnvelopeTriggered(envelopeHash, msg.sender, keeperReward);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Cancel
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Cancel an active envelope. Only callable by the position owner (issuer).
    /// @dev Unencumbers the position, making it available for regular intent execution again.
    function cancel(bytes32 envelopeHash) external nonReentrant {
        EnvelopeRecord storage record = envelopes[envelopeHash];
        if (record.status == EnvelopeStatus.None)   revert EnvelopeNotFound();
        if (record.status != EnvelopeStatus.Active) revert EnvelopeNotActive();
        if (record.issuer != msg.sender)            revert NotIssuer();

        record.status = EnvelopeStatus.Cancelled;
        vault.unencumber(record.envelope.positionCommitment);

        emit EnvelopeCancelled(envelopeHash);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Expire (permissionless cleanup)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Clean up an expired envelope. Callable by anyone.
    function expire(bytes32 envelopeHash) external nonReentrant {
        EnvelopeRecord storage record = envelopes[envelopeHash];
        if (record.status == EnvelopeStatus.None)   revert EnvelopeNotFound();
        if (record.status != EnvelopeStatus.Active) revert EnvelopeNotActive();
        if (record.envelope.expiry > block.timestamp) revert EnvelopeNotExpired();
        _expire(envelopeHash, record);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────────────────────────

    function getEnvelope(bytes32 envelopeHash)
        external view returns (EnvelopeRecord memory)
    {
        return envelopes[envelopeHash];
    }

    function isActive(bytes32 envelopeHash) external view returns (bool) {
        return envelopes[envelopeHash].status == EnvelopeStatus.Active;
    }

    /// @notice Compute the EIP-712 signing digest for a Capability against this registry's domain.
    ///         Used by agents to sign envelope.manage capabilities. NOT interchangeable with
    ///         the kernel's capabilityDigest — different domain separator, different digest.
    function capabilityDigest(Types.Capability calldata cap) external view returns (bytes32) {
        return _hashTypedDataV4(_hashCapability(cap));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────

    function _expire(bytes32 envelopeHash, EnvelopeRecord storage record) internal {
        record.status = EnvelopeStatus.Expired;
        vault.unencumber(record.envelope.positionCommitment);
        emit EnvelopeExpired(envelopeHash);
    }

    /// @notice Read one oracle feed and evaluate it against a threshold.
    ///
    /// @dev Security checks applied (in order):
    ///      M-2: oracle != address(0) — prevents opaque low-level revert when priceOracle is unset.
    ///      M-1: answeredInRound >= roundId — Chainlink best practice.  A round can be started but
    ///           not yet answered; in that state updatedAt may appear fresh while the answer is
    ///           stale.  Checking answeredInRound >= roundId catches this edge case.
    ///           updatedAt staleness check — belt-and-suspenders.
    ///           answer > 0 — circuit-breaker / sequencer-down guard.
    function _evalSingleCondition(
        address oracle,
        uint256 triggerPrice,
        Types.ComparisonOp op
    ) private view returns (bool) {
        // M-2: guard against address(0) oracle — would produce an opaque revert, not ConditionNotMet.
        if (oracle == address(0)) revert OracleInvalidAnswer();

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(oracle).latestRoundData();

        // M-1: Chainlink round completeness check — answeredInRound can be less than roundId
        // when a round was initiated but the aggregator has not yet received sufficient responses.
        // In that state updatedAt reflects the previous round's timestamp and the answer is stale.
        if (answeredInRound < roundId) revert OracleStale();

        if (updatedAt < block.timestamp - MAX_ORACLE_AGE) revert OracleStale();
        if (answer <= 0) revert OracleInvalidAnswer();

        uint256 price = uint256(answer);
        if (op == Types.ComparisonOp.LESS_THAN)    return price < triggerPrice;
        if (op == Types.ComparisonOp.GREATER_THAN) return price > triggerPrice;
        return price == triggerPrice;
    }

    /// @notice Evaluate the full condition tree and revert if not met.
    ///
    /// Single oracle: secondaryOracle == address(0) → only primary is checked.
    /// Compound OR:   fires when EITHER oracle condition is satisfied.
    /// Compound AND:  fires only when BOTH oracle conditions are satisfied.
    function _assertConditionMet(Types.Conditions calldata conditions) internal view {
        bool primaryMet = _evalSingleCondition(
            conditions.priceOracle,
            conditions.triggerPrice,
            conditions.op
        );

        // No secondary oracle — primary must hold alone.
        if (conditions.secondaryOracle == address(0)) {
            if (!primaryMet) revert ConditionNotMet();
            return;
        }

        bool secondaryMet = _evalSingleCondition(
            conditions.secondaryOracle,
            conditions.secondaryTriggerPrice,
            conditions.secondaryOp
        );

        bool met = conditions.logicOp == Types.LogicOp.OR
            ? primaryMet || secondaryMet
            : primaryMet && secondaryMet;

        if (!met) revert ConditionNotMet();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: EIP-712 hashing — delegates to HashLib (single source of truth)
    // ─────────────────────────────────────────────────────────────────────────

    function _hashCapability(Types.Capability memory cap) internal pure returns (bytes32) {
        return HashLib.hashCapability(cap);
    }
}
