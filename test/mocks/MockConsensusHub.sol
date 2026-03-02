// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockConsensusHub
/// @notice Application-layer M-of-N multi-agent consensus tracker for the Atlas demo.
///
/// Context:
///   Phase 1 of CapabilityKernel enforces delegationDepth == 0, meaning the kernel
///   currently verifies a single capability/intent pair. For institutional use cases
///   requiring that M independent agents sign off on a trade before it executes,
///   this hub provides the application-layer enforcement mirror.
///
///   In Phase 2, the Intent struct will gain a consensusPolicy field
///   (requiredSigners: M, approvedSignerSetRoot: merkle root of approved keys).
///   The kernel will accumulate M ECDSA signatures and verify the merkle inclusions
///   on-chain. MockConsensusHub is the Phase 1 preview of this primitive.
///
/// Demo flow (3-of-5 consensus):
///   1. Any signer proposes a trade intent hash.
///      MockConsensusHub records the proposal with a signer set and required count.
///   2. Signers call approve(proposalId) from their approved addresses.
///   3. Once approvalCount >= requiredApprovals, isExecutable(proposalId) returns true.
///   4. The UI submits the actual kernel execution (Atlas still enforces all capability bounds).
///
/// Security note:
///   This contract enforces that msg.sender is in the approved signer set.
///   The actual cryptographic guarantee (each signer holds an independent key) is
///   enforced by the Ethereum transaction model — an attacker cannot call approve()
///   from a signer's address without that key.
///
/// Phase 2 upgrade path:
///   Replace this with on-chain M ECDSA verification inside CapabilityKernel.executeIntent().
///   The interface would accept an array of (capability, capSig) tuples — one per signer —
///   and verify each against the consensusPolicy merkle root.
contract MockConsensusHub {

    // ─── Types ────────────────────────────────────────────────────────────────

    struct Proposal {
        bytes32   intentHash;
        uint8     requiredApprovals;
        uint8     approvalCount;
        bool      executed;
        bool      active;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    uint256 public proposalCount;

    mapping(bytes32 => Proposal)           public proposals;
    mapping(bytes32 => address[])          public signerSets;         // proposalId → approved signers
    mapping(bytes32 => mapping(address => bool)) public hasApproved;  // proposalId → signer → approved

    // ─── Events ───────────────────────────────────────────────────────────────

    event Proposed(bytes32 indexed proposalId, bytes32 indexed intentHash, uint8 required, address[] signers);
    event Approved(bytes32 indexed proposalId, address indexed signer, uint8 count, uint8 required);
    event Executed(bytes32 indexed proposalId);

    // ─── Actions ──────────────────────────────────────────────────────────────

    /// @notice Propose a new multi-agent trade intent.
    /// @param intentHash         keccak256 of the intent struct (for reference — not verified here).
    /// @param requiredApprovals  How many signers must approve before execution.
    /// @param approvedSigners    The set of addresses allowed to approve this proposal.
    function propose(
        bytes32   intentHash,
        uint8     requiredApprovals,
        address[] calldata approvedSigners
    ) external returns (bytes32 proposalId) {
        require(approvedSigners.length > 0, "MockConsensusHub: empty signer set");
        require(requiredApprovals > 0, "MockConsensusHub: requiredApprovals is zero");
        require(requiredApprovals <= approvedSigners.length, "MockConsensusHub: required > signer count");

        proposalId = keccak256(abi.encode(intentHash, block.timestamp, proposalCount));
        proposalCount++;

        proposals[proposalId] = Proposal({
            intentHash:        intentHash,
            requiredApprovals: requiredApprovals,
            approvalCount:     0,
            executed:          false,
            active:            true
        });

        for (uint256 i = 0; i < approvedSigners.length; i++) {
            signerSets[proposalId].push(approvedSigners[i]);
        }

        emit Proposed(proposalId, intentHash, requiredApprovals, approvedSigners);
    }

    /// @notice Approve a proposal. msg.sender must be in the proposal's approved signer set.
    function approve(bytes32 proposalId) external {
        Proposal storage prop = proposals[proposalId];
        require(prop.active, "MockConsensusHub: proposal not active");
        require(!prop.executed, "MockConsensusHub: already executed");
        require(!hasApproved[proposalId][msg.sender], "MockConsensusHub: already approved");

        // Verify msg.sender is in the approved signer set.
        address[] storage signers = signerSets[proposalId];
        bool found;
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == msg.sender) { found = true; break; }
        }
        require(found, "MockConsensusHub: caller not in signer set");

        hasApproved[proposalId][msg.sender] = true;
        prop.approvalCount++;

        emit Approved(proposalId, msg.sender, prop.approvalCount, prop.requiredApprovals);
    }

    /// @notice Mark a proposal as executed. Called by the UI after kernel.executeIntent() succeeds.
    function markExecuted(bytes32 proposalId) external {
        Proposal storage prop = proposals[proposalId];
        require(prop.active, "MockConsensusHub: proposal not active");
        require(!prop.executed, "MockConsensusHub: already executed");
        require(prop.approvalCount >= prop.requiredApprovals, "MockConsensusHub: threshold not met");
        prop.executed = true;
        emit Executed(proposalId);
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    /// @notice Returns true when the proposal has collected enough approvals.
    function isExecutable(bytes32 proposalId) external view returns (bool) {
        Proposal storage prop = proposals[proposalId];
        return prop.active && !prop.executed && prop.approvalCount >= prop.requiredApprovals;
    }

    function getApprovalCount(bytes32 proposalId) external view returns (uint8) {
        return proposals[proposalId].approvalCount;
    }

    function getSignerSet(bytes32 proposalId) external view returns (address[] memory) {
        return signerSets[proposalId];
    }

    function signerHasApproved(bytes32 proposalId, address signer) external view returns (bool) {
        return hasApproved[proposalId][signer];
    }
}
