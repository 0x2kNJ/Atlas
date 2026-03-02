// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ICircuit1Verifier} from "./interfaces/ICircuit1Verifier.sol";
import {IReceiptAccumulator} from "./interfaces/IReceiptAccumulator.sol";

/// @title CreditVerifier
/// @notice Accepts Circuit 1 proofs and issues on-chain credit attestations for AI agents.
///
/// ─── What This Contract Does ────────────────────────────────────────────────
///
/// An agent that has accumulated N repayment receipts through the Atlas kernel
/// can submit a Circuit 1 proof here. If valid, CreditVerifier records the agent's
/// proven repayment count and maps it to a Clawloan-compatible credit tier.
///
/// This replaces Clawloan's `CreditScoring.sol` chain-specific lookup with a
/// ZK-portable attestation: the proof can be generated once and verified on any
/// chain that has deployed CreditVerifier + ReceiptAccumulator.
///
/// ─── Credit Tiers (Clawloan-compatible) ─────────────────────────────────────
///
///   NEW      (0  repayments) → $10  max borrow
///   BRONZE   (1-5            → $50  max borrow
///   SILVER   (6-20)          → $200 max borrow
///   GOLD     (21-50)         → $500 max borrow
///   PLATINUM (50+)           → $1,000 max borrow
///
/// ─── Verifier Upgrade Path ───────────────────────────────────────────────────
///
/// Phase 1 (now): MockCircuit1Verifier — accepts plaintext receipt encoding, validates
///   by replaying the rolling hash. No ZK required. Full anti-fabrication guarantee
///   against the on-chain accumulator root.
///
/// Phase 2 (circuit ready): swap to the Noir-generated UltraHonk verifier via setVerifier().
///   The same PublicInputs schema is used. No other changes required.
///
/// ─── Clawloan Integration Path ───────────────────────────────────────────────
///
/// Option A (tight coupling): Clawloan's LendingPoolV2 calls getCreditTier(capabilityHash)
///   instead of CreditScoring.getScore(botId). The operator maps botId → capabilityHash.
///
/// Option B (looser coupling): Clawloan's credit system reads the CreditProofVerified event
///   off-chain and updates its on-chain score via a trusted relayer.
///
/// Option C (cross-chain): Agent submits the same proof on a new chain. CreditVerifier
///   on that chain has its own ReceiptAccumulator root (populated via a bridge or a
///   cross-chain nullifier coordinator). The proof verifies against the new chain's root.

contract CreditVerifier is Ownable2Step {

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    IReceiptAccumulator public immutable accumulator;

    /// @notice Current Circuit 1 verifier.
    ///         Phase 1: MockCircuit1Verifier.
    ///         Phase 2: Noir-generated UltraHonk verifier.
    ICircuit1Verifier public verifier;

    // ─────────────────────────────────────────────────────────────────────────
    // H-2: Verifier timelock — 2-day commit/execute pattern
    //
    // A single owner transaction can no longer instantly swap to a malicious verifier.
    // proposeVerifier() starts the clock; applyVerifier() completes the swap after
    // VERIFIER_TIMELOCK_DELAY has elapsed.  Observers have the full delay window to
    // detect a malicious proposal and react (revoke trust, pause dependent protocols).
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public constant VERIFIER_TIMELOCK_DELAY = 2 days;

    /// @notice Pending verifier proposal: the address that will replace `verifier`
    ///         once the timelock elapses.
    address public pendingVerifier;

    /// @notice Timestamp after which `applyVerifier()` may be called.
    ///         Zero means no proposal is active.
    uint256 public verifierProposalTime;

    /// @notice Per-capability credit record, once proven.
    struct CreditRecord {
        uint256 provenRepayments;  // number of receipts proven in the latest valid proof
        address adapterFilter;     // which adapter the receipts were filtered on (address(0) = unfiltered)
        uint256 provenAt;          // block.timestamp of the last successful proof submission
    }

    /// @notice Per-capability credit record.
    mapping(bytes32 capabilityHash => CreditRecord) public creditRecords;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event VerifierProposed(address indexed proposedVerifier, uint256 applicableAfter);
    event VerifierProposalCancelled(address indexed cancelledVerifier);
    event CreditProofVerified(
        bytes32 indexed capabilityHash,
        uint256 provenRepayments,
        uint8   creditTier,
        address adapterFilter,
        bytes32 accumulatorRoot
    );
    event VerifierUpdated(address indexed oldVerifier, address indexed newVerifier);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error InvalidProof();
    error NExceedsAccumulatedReceipts(uint256 claimed, uint256 actual);
    error AdapterReceiptCountMismatch(uint256 claimed, uint256 onChain);
    error ZeroAddress();
    error TimelockNotElapsed(uint256 applicableAfter, uint256 currentTime);
    error NoPendingVerifierProposal();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        address _accumulator,
        address _verifier,
        address _owner
    ) Ownable(_owner) {
        if (_accumulator == address(0)) revert ZeroAddress();
        if (_verifier    == address(0)) revert ZeroAddress();
        accumulator = IReceiptAccumulator(_accumulator);
        verifier    = ICircuit1Verifier(_verifier);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin — verifier upgrade (H-2: timelocked commit/execute pattern)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Step 1: propose a new verifier. Starts the 2-day timelock.
    ///         Call applyVerifier() after the delay to complete the swap.
    ///         Replaces any existing pending proposal (resets the clock).
    function proposeVerifier(address _verifier) external onlyOwner {
        if (_verifier == address(0)) revert ZeroAddress();
        pendingVerifier     = _verifier;
        verifierProposalTime = block.timestamp + VERIFIER_TIMELOCK_DELAY;
        emit VerifierProposed(_verifier, verifierProposalTime);
    }

    /// @notice Step 2: apply the pending verifier after the timelock has elapsed.
    function applyVerifier() external onlyOwner {
        if (pendingVerifier == address(0)) revert NoPendingVerifierProposal();
        if (block.timestamp < verifierProposalTime)
            revert TimelockNotElapsed(verifierProposalTime, block.timestamp);

        address oldVerifier  = address(verifier);
        verifier             = ICircuit1Verifier(pendingVerifier);
        pendingVerifier      = address(0);
        verifierProposalTime = 0;
        emit VerifierUpdated(oldVerifier, address(verifier));
    }

    /// @notice Cancel a pending verifier proposal before it is applied.
    function cancelVerifierProposal() external onlyOwner {
        if (pendingVerifier == address(0)) revert NoPendingVerifierProposal();
        address cancelled    = pendingVerifier;
        pendingVerifier      = address(0);
        verifierProposalTime = 0;
        emit VerifierProposalCancelled(cancelled);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core: submit proof
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Submit a Circuit 1 proof to attest an agent's credit tier.
    ///
    /// @param capabilityHash  The capability whose receipts are being proven.
    /// @param n               Number of receipts being proven (claimed credit evidence count).
    /// @param adapterFilter   Only count receipts through this adapter (e.g. ClawloanRepayAdapter).
    ///                        address(0) means prove all receipts regardless of adapter.
    /// @param minReturnBps    Minimum return constraint applied to every receipt in the proof.
    ///                        0 means no return floor.
    /// @param proof           Circuit 1 proof bytes.
    ///                        Phase 1: abi.encode(receiptHashes[], nullifiers[], amountsIn[], amountsOut[]).
    ///                        Phase 2: ~2 KB UltraHonk proof.
    function submitProof(
        bytes32 capabilityHash,
        uint256 n,
        address adapterFilter,
        uint256 minReturnBps,
        bytes calldata proof
    ) external {
        // ── Sanity: n cannot exceed total accumulated receipts ────────────────
        uint256 totalReceipts = accumulator.receiptCount(capabilityHash);
        if (n > totalReceipts) revert NExceedsAccumulatedReceipts(n, totalReceipts);

        // ── If adapterFilter set: n cannot exceed adapter-filtered count ──────
        // This check prevents a proof claiming N ClawloanRepay receipts when there
        // are fewer than N ClawloanRepay receipts on-chain.
        if (adapterFilter != address(0)) {
            uint256 adapterCount = accumulator.adapterReceiptCount(capabilityHash, adapterFilter);
            if (n > adapterCount) revert AdapterReceiptCountMismatch(n, adapterCount);
        }

        // ── Read the accumulator root after exactly n receipts ───────────────
        //
        // H-3 fix: when adapterFilter is set, use the per-adapter rolling root instead of
        // the global per-capability root.  The global root is computed over ALL receipts in
        // chronological order — if receipts from different adapters are interleaved, an agent
        // cannot prove adapter-filtered credit because the global root[N] includes non-target
        // receipts.  The per-adapter root is built only from receipts through `adapterFilter`,
        // so the circuit can always prove N consecutive adapter-specific receipts regardless
        // of how other receipts are ordered.
        bytes32 targetRoot = adapterFilter != address(0)
            ? accumulator.adapterRootAtIndex(capabilityHash, adapterFilter, n)
            : accumulator.rootAtIndex(capabilityHash, n);

        ICircuit1Verifier.PublicInputs memory inputs = ICircuit1Verifier.PublicInputs({
            capabilityHash:  capabilityHash,
            n:               n,
            accumulatorRoot: targetRoot,
            adapterFilter:   adapterFilter,
            minReturnBps:    minReturnBps
        });

        // ── Verify ────────────────────────────────────────────────────────────
        if (!verifier.verify(proof, inputs)) revert InvalidProof();

        // ── Record credit attestation (M-4: prevent adapterFilter widening) ────
        //
        // Once a capability proves adapter-specific credit (adapterFilter != address(0)),
        // subsequent proofs must use the SAME adapterFilter or also be adapter-specific
        // with a higher n.  Allowing a switch to adapterFilter=address(0) would let
        // an attacker dilute a Clawloan-specific attestation with a weaker all-adapters
        // proof — Clawloan integrators checking rec.adapterFilter would see address(0)
        // instead of ClawloanRepayAdapter, misinterpreting the credit as unfiltered.
        CreditRecord storage rec = creditRecords[capabilityHash];
        bool filterConflict = (rec.adapterFilter != address(0)) && (adapterFilter != rec.adapterFilter);
        if (n >= rec.provenRepayments && !filterConflict) {
            rec.provenRepayments = n;
            rec.adapterFilter    = adapterFilter;
            rec.provenAt         = block.timestamp;
        }

        uint8 tier = _tierFor(n);

        emit CreditProofVerified(capabilityHash, n, tier, adapterFilter, targetRoot);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View: credit tier
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the Clawloan-compatible credit tier for a capability.
    ///         0 = NEW, 1 = BRONZE, 2 = SILVER, 3 = GOLD, 4 = PLATINUM
    function getCreditTier(bytes32 capabilityHash) external view returns (uint8) {
        return _tierFor(creditRecords[capabilityHash].provenRepayments);
    }

    /// @notice Returns the maximum borrow amount (USDC, 6 decimals) for a capability.
    function getMaxBorrow(bytes32 capabilityHash) external view returns (uint256) {
        uint8 tier = _tierFor(creditRecords[capabilityHash].provenRepayments);
        if (tier == 4) return 1_000e6;   // PLATINUM
        if (tier == 3) return   500e6;   // GOLD
        if (tier == 2) return   200e6;   // SILVER
        if (tier == 1) return    50e6;   // BRONZE
        return 10e6;                     // NEW
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────

    function _tierFor(uint256 n) internal pure returns (uint8) {
        if (n >= 50) return 4;  // PLATINUM
        if (n >= 21) return 3;  // GOLD
        if (n >= 6)  return 2;  // SILVER
        if (n >= 1)  return 1;  // BRONZE
        return 0;               // NEW
    }
}
