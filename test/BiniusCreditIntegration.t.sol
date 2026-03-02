// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ReceiptAccumulatorSHA256} from "../contracts/ReceiptAccumulatorSHA256.sol";
import {CreditVerifier} from "../contracts/CreditVerifier.sol";
import {BiniusCircuit1Verifier} from "../contracts/verifiers/BiniusCircuit1Verifier.sol";
import {ICircuit1Verifier} from "../contracts/interfaces/ICircuit1Verifier.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice End-to-end integration test:
///   ReceiptAccumulatorSHA256  ←  CreditVerifier  →  BiniusCircuit1Verifier
///
/// Simulates the full agent credit flow:
///   1. Agent accumulates receipts (SHA-256 rolling root)
///   2. Agent generates Binius64 proof off-chain (173ms)
///   3. Attester verifies proof off-chain (47ms) and signs attestation
///   4. Attestation submitted on-chain → CreditVerifier records credit tier
contract BiniusCreditIntegrationTest is Test {
    using MessageHashUtils for bytes32;

    ReceiptAccumulatorSHA256 internal acc;
    CreditVerifier internal creditVerifier;
    BiniusCircuit1Verifier internal biniusVerifier;

    address internal owner   = makeAddr("owner");
    address internal kernel  = makeAddr("kernel");
    address internal adapter = address(0xabCDEF1234567890ABcDEF1234567890aBCDeF12);
    address internal agent   = makeAddr("agent");

    uint256 internal attesterPk;
    address internal attester;

    function setUp() public {
        (attester, attesterPk) = makeAddrAndKey("attester");

        // Deploy accumulator
        acc = new ReceiptAccumulatorSHA256(owner);
        vm.prank(owner);
        acc.setKernel(kernel);

        // Deploy Binius verifier with the attester
        biniusVerifier = new BiniusCircuit1Verifier(owner, attester);

        // Deploy CreditVerifier pointing at SHA256 accumulator + Binius verifier
        creditVerifier = new CreditVerifier(
            address(acc),
            address(biniusVerifier),
            owner
        );
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _accumulate(bytes32 cap, uint256 idx) internal {
        bytes32 receiptHash = bytes32(uint256(0x1000 + idx));
        bytes32 nullifier   = bytes32(uint256(0x2000 + idx));
        vm.prank(kernel);
        acc.accumulate(cap, receiptHash, nullifier, adapter, 500e6, 505e6);
    }

    function _buildAttestation(
        bytes32 proofDigest,
        ICircuit1Verifier.PublicInputs memory inputs
    ) internal view returns (bytes memory proof) {
        bytes32 message = keccak256(
            abi.encodePacked(
                proofDigest,
                inputs.capabilityHash,
                inputs.n,
                inputs.accumulatorRoot,
                inputs.adapterFilter,
                inputs.minReturnBps
            )
        );
        bytes32 ethSignedHash = message.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterPk, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        proof = abi.encode(proofDigest, signature);
    }

    // ─── Tests: BiniusCircuit1Verifier standalone ─────────────────────────────

    function testAttesterIsAuthorized() public view {
        assertTrue(biniusVerifier.attesters(attester));
    }

    function testVerifyWithValidAttestation() public {
        bytes32 proofDigest = keccak256("test-proof-bytes");
        ICircuit1Verifier.PublicInputs memory inputs = ICircuit1Verifier.PublicInputs({
            capabilityHash: bytes32(uint256(1)),
            n: 4,
            accumulatorRoot: bytes32(uint256(0xAABB)),
            adapterFilter: adapter,
            minReturnBps: 10000
        });

        bytes memory proof = _buildAttestation(proofDigest, inputs);
        bool ok = biniusVerifier.verify(proof, inputs);
        assertTrue(ok);
    }

    function testRejectReplayedProof() public {
        bytes32 proofDigest = keccak256("replay-test");
        ICircuit1Verifier.PublicInputs memory inputs = ICircuit1Verifier.PublicInputs({
            capabilityHash: bytes32(uint256(1)),
            n: 2,
            accumulatorRoot: bytes32(uint256(0xCC)),
            adapterFilter: address(0),
            minReturnBps: 0
        });

        bytes memory proof = _buildAttestation(proofDigest, inputs);
        biniusVerifier.verify(proof, inputs);

        vm.expectRevert(
            abi.encodeWithSelector(BiniusCircuit1Verifier.ProofAlreadyUsed.selector, proofDigest)
        );
        biniusVerifier.verify(proof, inputs);
    }

    function testRejectUnauthorizedAttester() public {
        (address rando, uint256 randoPk) = makeAddrAndKey("rando");

        bytes32 proofDigest = keccak256("rando-proof");
        ICircuit1Verifier.PublicInputs memory inputs = ICircuit1Verifier.PublicInputs({
            capabilityHash: bytes32(uint256(1)),
            n: 1,
            accumulatorRoot: bytes32(uint256(0xDD)),
            adapterFilter: address(0),
            minReturnBps: 0
        });

        // Sign with unauthorized key
        bytes32 message = keccak256(
            abi.encodePacked(
                proofDigest,
                inputs.capabilityHash,
                inputs.n,
                inputs.accumulatorRoot,
                inputs.adapterFilter,
                inputs.minReturnBps
            )
        );
        bytes32 ethSignedHash = message.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(randoPk, ethSignedHash);
        bytes memory proof = abi.encode(proofDigest, abi.encodePacked(r, s, v));

        vm.expectRevert(
            abi.encodeWithSelector(BiniusCircuit1Verifier.UnauthorizedAttester.selector, rando)
        );
        biniusVerifier.verify(proof, inputs);
    }

    function testOwnerCanAddRemoveAttester() public {
        address newAttester = makeAddr("new-attester");

        vm.prank(owner);
        biniusVerifier.setAttester(newAttester, true);
        assertTrue(biniusVerifier.attesters(newAttester));

        vm.prank(owner);
        biniusVerifier.setAttester(newAttester, false);
        assertFalse(biniusVerifier.attesters(newAttester));
    }

    // ─── Tests: Full integration (accumulate → attest → credit tier) ──────────

    function testFullCreditFlow_Bronze() public {
        bytes32 cap = bytes32(uint256(42));

        // Accumulate 4 receipts through the SHA-256 accumulator
        for (uint256 i = 0; i < 4; i++) {
            _accumulate(cap, i);
        }

        // Read the on-chain root after 4 receipts
        bytes32 root = acc.rootAtIndex(cap, 4);
        assertNotEq(root, bytes32(0));

        // Build attestation (simulating: agent proved, attester verified)
        bytes32 proofDigest = keccak256("binius64-proof-for-cap-42");
        ICircuit1Verifier.PublicInputs memory inputs = ICircuit1Verifier.PublicInputs({
            capabilityHash: cap,
            n: 4,
            accumulatorRoot: root,
            adapterFilter: adapter,
            minReturnBps: 0
        });
        bytes memory proof = _buildAttestation(proofDigest, inputs);

        // Submit to CreditVerifier
        vm.prank(agent);
        creditVerifier.submitProof(cap, 4, adapter, 0, proof);

        // Verify credit tier: 4 repayments → BRONZE (tier 1)
        assertEq(creditVerifier.getCreditTier(cap), 1);
        assertEq(creditVerifier.getMaxBorrow(cap), 50e6); // $50
    }

    function testFullCreditFlow_Silver() public {
        bytes32 cap = bytes32(uint256(99));

        // Accumulate 10 receipts
        for (uint256 i = 0; i < 10; i++) {
            _accumulate(cap, i);
        }

        bytes32 root = acc.rootAtIndex(cap, 10);
        bytes32 proofDigest = keccak256("binius64-proof-silver");
        ICircuit1Verifier.PublicInputs memory inputs = ICircuit1Verifier.PublicInputs({
            capabilityHash: cap,
            n: 10,
            accumulatorRoot: root,
            adapterFilter: adapter,
            minReturnBps: 0
        });
        bytes memory proof = _buildAttestation(proofDigest, inputs);

        vm.prank(agent);
        creditVerifier.submitProof(cap, 10, adapter, 0, proof);

        // 10 repayments → SILVER (tier 2)
        assertEq(creditVerifier.getCreditTier(cap), 2);
        assertEq(creditVerifier.getMaxBorrow(cap), 200e6); // $200
    }

    function testFullCreditFlow_NoFilter() public {
        bytes32 cap = bytes32(uint256(77));

        // Accumulate 2 receipts
        for (uint256 i = 0; i < 2; i++) {
            _accumulate(cap, i);
        }

        // Prove with no adapter filter (use global root)
        bytes32 root = acc.rootAtIndex(cap, 2);
        bytes32 proofDigest = keccak256("binius64-proof-nofilter");
        ICircuit1Verifier.PublicInputs memory inputs = ICircuit1Verifier.PublicInputs({
            capabilityHash: cap,
            n: 2,
            accumulatorRoot: root,
            adapterFilter: address(0),
            minReturnBps: 0
        });
        bytes memory proof = _buildAttestation(proofDigest, inputs);

        vm.prank(agent);
        creditVerifier.submitProof(cap, 2, address(0), 0, proof);

        // 2 repayments → BRONZE (tier 1)
        assertEq(creditVerifier.getCreditTier(cap), 1);
    }

    function testRejectNExceedsAccumulated() public {
        bytes32 cap = bytes32(uint256(88));
        _accumulate(cap, 0);

        // Try to claim 5 receipts when only 1 exists
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(CreditVerifier.NExceedsAccumulatedReceipts.selector, 5, 1)
        );
        creditVerifier.submitProof(cap, 5, address(0), 0, "");
    }

    function testCreditTierUpgrade() public {
        bytes32 cap = bytes32(uint256(55));

        // First: prove 3 receipts → BRONZE
        for (uint256 i = 0; i < 3; i++) {
            _accumulate(cap, i);
        }
        {
            bytes32 root = acc.rootAtIndex(cap, 3);
            bytes32 pd = keccak256("proof-bronze");
            ICircuit1Verifier.PublicInputs memory inp = ICircuit1Verifier.PublicInputs({
                capabilityHash: cap,
                n: 3,
                accumulatorRoot: root,
                adapterFilter: adapter,
                minReturnBps: 0
            });
            vm.prank(agent);
            creditVerifier.submitProof(cap, 3, adapter, 0, _buildAttestation(pd, inp));
        }
        assertEq(creditVerifier.getCreditTier(cap), 1); // BRONZE

        // Accumulate more → prove 25 → GOLD
        for (uint256 i = 3; i < 25; i++) {
            _accumulate(cap, i);
        }
        {
            bytes32 root = acc.adapterRootAtIndex(cap, adapter, 25);
            bytes32 pd = keccak256("proof-gold");
            ICircuit1Verifier.PublicInputs memory inp = ICircuit1Verifier.PublicInputs({
                capabilityHash: cap,
                n: 25,
                accumulatorRoot: root,
                adapterFilter: adapter,
                minReturnBps: 0
            });
            vm.prank(agent);
            creditVerifier.submitProof(cap, 25, adapter, 0, _buildAttestation(pd, inp));
        }
        assertEq(creditVerifier.getCreditTier(cap), 3); // GOLD
        assertEq(creditVerifier.getMaxBorrow(cap), 500e6); // $500
    }
}
