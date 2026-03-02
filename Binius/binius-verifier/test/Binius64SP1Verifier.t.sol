// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/Binius64SP1Verifier.sol";
import "./mocks/MockSP1Verifier.sol";

/// @notice Tests for Binius64SP1Verifier.
///
/// Key things tested:
///   - Correctness: verify succeeds/fails, events emitted
///   - Security: circuit registry enforcement
///   - New features: batchVerify, verifyAndCall
///   - Gas benchmarks: overhead only (MockSP1Verifier, no pairing)
///
/// Gas model reminder:
///   - MockSP1Verifier measures contract overhead (ABI decode, registry, event).
///   - Real SP1 Groth16 verifier adds ~220K gas for BN254 pairing (measured mainnet).
///   - Calldata: 96 bytes pubValues + ~256 bytes proof + 68 bytes overhead ≈ 6.7K gas.
///   - Total real cost: overhead + 220K + 6.7K + 21K (base tx) ≈ 250-260K gas.

contract Binius64SP1VerifierTest is Test {

    MockSP1Verifier public mockSP1;
    Binius64SP1Verifier public verifier;

    // Real vkey from compiled guest program (v0.1.0, circuit_id security-fix).
    // Recompute with: cd sp1-guest && cargo run --bin prove -- vkey
    bytes32 constant REAL_VKEY =
        0x00c8508697673f052b007f80dadec4ea96d520efc69aaf7ab7d322e0eb60d868;

    // Real circuit ID for the subset-sum test circuit.
    // keccak256(circuit.cs bytes) — verified by simulation test output.
    bytes32 constant SUBSET_SUM_CIRCUIT_ID =
        0x7dbff8a54752e13f22ab0cc5d1ac844ef04c93408eb7c21412a6238e95fcff91;

    bytes32 constant OTHER_CIRCUIT_ID =
        bytes32(uint256(0xCAFEBABE));

    bytes public syntheticPublicValues;
    bytes public syntheticProof;

    function setUp() public {
        mockSP1 = new MockSP1Verifier();
        verifier = new Binius64SP1Verifier(address(mockSP1), REAL_VKEY);

        // publicValues = abi.encode(bytes32, bytes32, bytes32) — 96 bytes, all fixed-size.
        bytes32 pubInputsHash = keccak256(abi.encode(uint256(10), uint256(20), uint256(70)));
        bytes32 proofHash = keccak256("subset-sum-proof");
        syntheticPublicValues = abi.encode(SUBSET_SUM_CIRCUIT_ID, pubInputsHash, proofHash);

        // SP1 Groth16 proof is ~256 bytes on mainnet
        syntheticProof = new bytes(256);
        for (uint256 i = 0; i < 256; i++) {
            syntheticProof[i] = bytes1(uint8(i % 256));
        }
    }

    // -----------------------------------------------------------------------
    //  Constructor / immutables
    // -----------------------------------------------------------------------

    function test_constructor_stores_sp1_and_vkey() public view {
        assertEq(address(verifier.SP1_VERIFIER()), address(mockSP1));
        assertEq(verifier.BINIUS64_VKEY(), REAL_VKEY);
        assertEq(verifier.owner(), address(this));
        assertFalse(verifier.circuitRegistryEnabled());
    }

    function test_constructor_reverts_zero_sp1_verifier() public {
        vm.expectRevert(Binius64SP1Verifier.ZeroSP1VerifierAddress.selector);
        new Binius64SP1Verifier(address(0), REAL_VKEY);
    }

    function test_constructor_reverts_zero_vkey() public {
        vm.expectRevert(Binius64SP1Verifier.ZeroBinius64VKey.selector);
        new Binius64SP1Verifier(address(mockSP1), bytes32(0));
    }

    // -----------------------------------------------------------------------
    //  Basic verify() — registry disabled (permissionless)
    // -----------------------------------------------------------------------

    function test_verify_succeeds_registry_disabled() public {
        mockSP1.setMode(MockSP1Verifier.Mode.PASS);
        verifier.verify(syntheticPublicValues, syntheticProof);
    }

    function test_verify_reverts_on_invalid_sp1_proof() public {
        mockSP1.setMode(MockSP1Verifier.Mode.FAIL);
        vm.expectRevert("MockSP1Verifier: proof rejected");
        verifier.verify(syntheticPublicValues, syntheticProof);
    }

    function test_verify_emits_ProofVerified_event() public {
        mockSP1.setMode(MockSP1Verifier.Mode.PASS);
        // Check only the circuitId (topic1) and submitter (topic3); skip publicInputsHash (topic2)
        vm.expectEmit(true, false, true, false);
        emit Binius64SP1Verifier.ProofVerified(SUBSET_SUM_CIRCUIT_ID, bytes32(0), address(this));
        verifier.verify(syntheticPublicValues, syntheticProof);
    }

    function test_verifyView_succeeds() public {
        verifier.verifyView(syntheticPublicValues, syntheticProof);
    }

    // -----------------------------------------------------------------------
    //  Circuit registry
    // -----------------------------------------------------------------------

    function test_registry_blocks_unregistered_circuit() public {
        verifier.setCircuitRegistryEnabled(true);
        // circuit not registered — should revert
        vm.expectRevert(
            abi.encodeWithSelector(Binius64SP1Verifier.CircuitNotRegistered.selector, SUBSET_SUM_CIRCUIT_ID)
        );
        verifier.verify(syntheticPublicValues, syntheticProof);
    }

    function test_registry_accepts_registered_circuit() public {
        verifier.registerCircuit(SUBSET_SUM_CIRCUIT_ID);
        verifier.setCircuitRegistryEnabled(true);
        mockSP1.setMode(MockSP1Verifier.Mode.PASS);
        verifier.verify(syntheticPublicValues, syntheticProof); // should not revert
    }

    function test_deregister_blocks_previously_registered_circuit() public {
        verifier.registerCircuit(SUBSET_SUM_CIRCUIT_ID);
        verifier.deregisterCircuit(SUBSET_SUM_CIRCUIT_ID);
        verifier.setCircuitRegistryEnabled(true);
        vm.expectRevert(
            abi.encodeWithSelector(Binius64SP1Verifier.CircuitNotRegistered.selector, SUBSET_SUM_CIRCUIT_ID)
        );
        verifier.verify(syntheticPublicValues, syntheticProof);
    }

    function test_toggle_registry_disabled_allows_unregistered() public {
        verifier.setCircuitRegistryEnabled(true);
        verifier.setCircuitRegistryEnabled(false); // re-disable
        mockSP1.setMode(MockSP1Verifier.Mode.PASS);
        verifier.verify(syntheticPublicValues, syntheticProof); // should succeed
    }

    function test_only_owner_can_register_circuit() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(Binius64SP1Verifier.Unauthorized.selector);
        verifier.registerCircuit(SUBSET_SUM_CIRCUIT_ID);
    }

    function test_only_owner_can_toggle_registry() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(Binius64SP1Verifier.Unauthorized.selector);
        verifier.setCircuitRegistryEnabled(true);
    }

    function test_ownership_transfer() public {
        address newOwner = address(0xABCD);
        verifier.transferOwnership(newOwner);
        assertEq(verifier.owner(), newOwner);
        // old owner cannot act
        vm.expectRevert(Binius64SP1Verifier.Unauthorized.selector);
        verifier.registerCircuit(SUBSET_SUM_CIRCUIT_ID);
        // new owner can act
        vm.prank(newOwner);
        verifier.registerCircuit(SUBSET_SUM_CIRCUIT_ID);
    }

    // -----------------------------------------------------------------------
    //  batchVerify()
    // -----------------------------------------------------------------------

    function test_batchVerify_two_proofs() public {
        mockSP1.setMode(MockSP1Verifier.Mode.PASS);
        bytes[] memory pva = new bytes[](2);
        bytes[] memory pa = new bytes[](2);
        pva[0] = syntheticPublicValues; pa[0] = syntheticProof;
        pva[1] = syntheticPublicValues; pa[1] = syntheticProof;
        verifier.batchVerify(pva, pa);
        // MockSP1Verifier.callCount should be 2
        assertEq(mockSP1.callCount(), 2);
    }

    function test_batchVerify_reverts_on_length_mismatch() public {
        bytes[] memory pva = new bytes[](2);
        bytes[] memory pa = new bytes[](1);
        pva[0] = syntheticPublicValues; pva[1] = syntheticPublicValues;
        pa[0] = syntheticProof;
        vm.expectRevert("length mismatch");
        verifier.batchVerify(pva, pa);
    }

    function test_batchVerify_fails_if_any_proof_invalid() public {
        mockSP1.setMode(MockSP1Verifier.Mode.FAIL);
        bytes[] memory pva = new bytes[](1);
        bytes[] memory pa = new bytes[](1);
        pva[0] = syntheticPublicValues; pa[0] = syntheticProof;
        vm.expectRevert("MockSP1Verifier: proof rejected");
        verifier.batchVerify(pva, pa);
    }

    function test_batchVerify_registry_check() public {
        verifier.setCircuitRegistryEnabled(true);
        bytes[] memory pva = new bytes[](1);
        bytes[] memory pa = new bytes[](1);
        pva[0] = syntheticPublicValues; pa[0] = syntheticProof;
        vm.expectRevert(
            abi.encodeWithSelector(Binius64SP1Verifier.CircuitNotRegistered.selector, SUBSET_SUM_CIRCUIT_ID)
        );
        verifier.batchVerify(pva, pa);
    }

    // -----------------------------------------------------------------------
    //  verifyAndCall()
    // -----------------------------------------------------------------------

    function test_verifyAndCall_calls_target() public {
        mockSP1.setMode(MockSP1Verifier.Mode.PASS);
        // Call mockSP1.callCount() as a harmless read-only target
        bytes memory callData = abi.encodeWithSignature("callCount()");
        bytes memory result = verifier.verifyAndCall(
            syntheticPublicValues, syntheticProof, address(mockSP1), callData
        );
        uint256 count = abi.decode(result, (uint256));
        // verifyProof was called once internally, then callCount() reads it
        assertEq(count, 1);
    }

    function test_verifyAndCall_reverts_if_proof_invalid() public {
        mockSP1.setMode(MockSP1Verifier.Mode.FAIL);
        vm.expectRevert("MockSP1Verifier: proof rejected");
        verifier.verifyAndCall(
            syntheticPublicValues, syntheticProof, address(mockSP1),
            abi.encodeWithSignature("callCount()")
        );
    }

    function test_verifyAndCall_reverts_if_target_reverts() public {
        mockSP1.setMode(MockSP1Verifier.Mode.PASS);
        // callData that will revert on MockSP1Verifier
        bytes memory badCallData = abi.encodeWithSignature("nonexistentFunction()");
        vm.expectRevert("target call failed");
        verifier.verifyAndCall(
            syntheticPublicValues, syntheticProof, address(mockSP1), badCallData
        );
    }

    // -----------------------------------------------------------------------
    //  Gas benchmarks
    // -----------------------------------------------------------------------

    function test_bench_verify_overhead() public {
        mockSP1.setMode(MockSP1Verifier.Mode.PASS);
        // Warm up mockSP1.callCount slot (SSTORE 0→1 costs 20K; subsequent writes are 2.9K)
        verifier.verify(syntheticPublicValues, syntheticProof);
        uint256 g = gasleft();
        verifier.verify(syntheticPublicValues, syntheticProof);
        uint256 gasUsed = g - gasleft();
        emit log_named_uint("verify() overhead warm (mock SP1, excl. pairing)", gasUsed);
        // Warm overhead (storage slot already written) is dominated by ProofVerified event
        // Real mainnet overhead will be similar since SP1 gateway also has warm storage.
        assertLt(gasUsed, 15_000, "warm overhead should be < 15K");
    }

    function test_bench_verifyView_overhead() public {
        // verifyView has no event and no registry check — pure dispatch overhead
        uint256 g = gasleft();
        verifier.verifyView(syntheticPublicValues, syntheticProof);
        uint256 gasUsed = g - gasleft();
        emit log_named_uint("verifyView() overhead (excl. pairing)", gasUsed);
        // Includes first-time MockSP1Verifier callCount SSTORE (20K) — cold path
        assertLt(gasUsed, 70_000, "cold verifyView overhead should be < 70K");
    }

    function test_bench_batchVerify_two_proofs() public {
        mockSP1.setMode(MockSP1Verifier.Mode.PASS);
        bytes[] memory pva = new bytes[](2);
        bytes[] memory pa = new bytes[](2);
        for (uint256 i; i < 2; i++) { pva[i] = syntheticPublicValues; pa[i] = syntheticProof; }
        uint256 g = gasleft();
        verifier.batchVerify(pva, pa);
        uint256 gasUsed = g - gasleft();
        emit log_named_uint("batchVerify(2) overhead (mock SP1)", gasUsed);
        emit log_named_uint("  per-proof overhead", gasUsed / 2);
    }

    function test_bench_total_estimate_l1() public {
        mockSP1.setMode(MockSP1Verifier.Mode.PASS);
        // Warm up storage slots first so we measure steady-state cost
        verifier.verify(syntheticPublicValues, syntheticProof);
        uint256 g = gasleft();
        verifier.verify(syntheticPublicValues, syntheticProof);
        uint256 overhead = g - gasleft();

        uint256 sp1PairingCost = 220_000; // BN254 Groth16 (mainnet benchmark, warm)
        // Calldata: 96 bytes pubValues + 256 bytes proof + 4-byte selector + 2x32 ABI headers = 420 bytes
        uint256 calldataCost   = 420 * 16; // 6720 gas
        uint256 baseTx         = 21_000;
        uint256 total          = overhead + sp1PairingCost + calldataCost + baseTx;

        emit log_named_uint("Contract overhead (ABI decode + registry + event, warm)", overhead);
        emit log_named_uint("SP1 Groth16 pairing (mainnet benchmark)", sp1PairingCost);
        emit log_named_uint("Calldata (~420 bytes x 16 gas/byte)", calldataCost);
        emit log_named_uint("Base transaction", baseTx);
        emit log_named_uint("TOTAL estimated (L1 mainnet)", total);
        emit log_named_uint("vs Native Solidity verifier (Yul+ZechTables)", 71_000_000);
        emit log_named_uint("Speedup factor (native / SP1)", 71_000_000 / total);

        assertLt(total, 260_000, "total should be under 260K gas (warm)");
    }
}
