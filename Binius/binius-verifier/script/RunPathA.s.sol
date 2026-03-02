// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/Binius64SP1Verifier.sol";
import "../test/mocks/MockSP1Verifier.sol";

/// @notice End-to-end local demo script for Path A (SP1-wrapped Binius64 verification).
///
/// What this script demonstrates:
///   1. Deploy MockSP1Verifier (stand-in for SP1VerifierGateway on mainnet)
///   2. Deploy Binius64SP1Verifier with the real VKEY from the compiled guest program
///   3. Register the test circuit ID (subset-sum circuit, 5 words)
///   4. Submit a synthetic SP1 proof packet and verify it succeeds
///   5. Demonstrate batchVerify and verifyAndCall patterns
///
/// Real vkey derived from: cd sp1-guest && cargo run --bin prove -- vkey
/// Guest program version:  binius64-sp1-program v0.1.0 (circuit_id computed in-guest)
///
/// To run with real proof files from /tmp/binius-test-proof/:
///   forge script script/RunPathA.s.sol -vvvv
contract RunPathA is Script {

    // Real VKEY from the compiled guest program (circuit_id security-fix version).
    // Recompute after any guest program change:
    //   cd sp1-guest && cargo run --bin prove -- vkey
    bytes32 constant BINIUS64_VKEY =
        0x00c8508697673f052b007f80dadec4ea96d520efc69aaf7ab7d322e0eb60d868;

    // Real circuit ID for the subset-sum test circuit (keccak256 of circuit.cs bytes).
    // Computed by: cargo run --bin prove -- info --cs /tmp/binius-test-proof/circuit.cs ...
    // Verified to match: guest program output during simulation test.
    bytes32 constant SUBSET_SUM_CIRCUIT_ID =
        0x7dbff8a54752e13f22ab0cc5d1ac844ef04c93408eb7c21412a6238e95fcff91;

    function run() external {
        vm.startBroadcast();

        // ---- Step 1: Deploy contracts ----------------------------------------
        MockSP1Verifier mockSP1 = new MockSP1Verifier();
        console.log("\nStep 1 | MockSP1Verifier deployed:     ", address(mockSP1));

        Binius64SP1Verifier verifier = new Binius64SP1Verifier(address(mockSP1), BINIUS64_VKEY);
        console.log("Step 1 | Binius64SP1Verifier deployed: ", address(verifier));

        // ---- Step 2: Verify vkey matches ----------------------------------------
        console.log("\nStep 2 | BINIUS64_VKEY (from guest ELF):");
        console.logBytes32(verifier.BINIUS64_VKEY());
        assert(verifier.BINIUS64_VKEY() == BINIUS64_VKEY);

        // ---- Step 3: Register the subset-sum test circuit -----------------------
        verifier.registerCircuit(SUBSET_SUM_CIRCUIT_ID);
        verifier.setCircuitRegistryEnabled(true);
        console.log("\nStep 3 | Circuit registered and registry enabled.");
        console.log("         circuit_id:", vm.toString(SUBSET_SUM_CIRCUIT_ID));
        assert(verifier.registeredCircuits(SUBSET_SUM_CIRCUIT_ID));

        // ---- Step 4: Build the proof packet -------------------------------------
        // In production these come from: cargo run --bin prove -- prove
        // Here we use the real circuit_id and synthetic hashes to exercise the decode path.
        bytes32 publicInputsHash = keccak256(abi.encode(
            uint256(10), uint256(20), uint256(30), uint256(40), // values
            uint256(70)                                          // target
        ));
        bytes32 proofHash = keccak256("subset-sum-proof-v1");

        // publicValues = abi.encode(circuitId, publicInputsHash, proofHash) = 96 bytes
        bytes memory publicValues = abi.encode(SUBSET_SUM_CIRCUIT_ID, publicInputsHash, proofHash);

        // SP1 Groth16 proof is ~256 bytes on mainnet; synthetic here
        bytes memory sp1Proof = new bytes(256);
        for (uint256 i = 0; i < 256; i++) sp1Proof[i] = bytes1(uint8(i % 256));

        console.log("\nStep 4 | Proof packet:");
        console.log("         circuitId:       ", vm.toString(SUBSET_SUM_CIRCUIT_ID));
        console.log("         pubInputsHash:   ", vm.toString(publicInputsHash));
        console.log("         proofHash:       ", vm.toString(proofHash));
        console.log("         publicValues len:", publicValues.length, "(should be 96)");
        assert(publicValues.length == 96);

        // ---- Step 5: Single verify() --------------------------------------------
        uint256 gasBefore = gasleft();
        verifier.verify(publicValues, sp1Proof);
        uint256 gasOverhead = gasBefore - gasleft();

        console.log("\nStep 5 | verify() succeeded!");
        console.log("         Contract overhead (excl. SP1 pairing):", gasOverhead);
        console.log("         Add ~220K for real SP1 BN254 Groth16 pairing on mainnet");
        console.log("         Estimated total on L1: ~", gasOverhead + 220_000 + 15_872 + 21_000);

        // ---- Step 6: batchVerify() — two proofs in one tx -----------------------
        bytes[] memory pubValArr = new bytes[](2);
        bytes[] memory proofArr = new bytes[](2);
        pubValArr[0] = publicValues;
        pubValArr[1] = publicValues;
        proofArr[0] = sp1Proof;
        proofArr[1] = sp1Proof;

        gasBefore = gasleft();
        verifier.batchVerify(pubValArr, proofArr);
        uint256 batchGas = gasBefore - gasleft();
        console.log("\nStep 6 | batchVerify(2 proofs) overhead:", batchGas, "gas");
        console.log("         Per-proof overhead: ~", batchGas / 2);
        console.log("         Base tx saved: ~21K per extra proof in batch");

        // ---- Step 7: verifyAndCall() — prove-and-enforce pattern ----------------
        // In production this would call EnvelopeRegistry.enforce(eid, oracleData).
        // Here we call a harmless read-only view as a demo.
        bytes memory callData = abi.encodeWithSignature("callCount()");
        gasBefore = gasleft();
        bytes memory result = verifier.verifyAndCall(publicValues, sp1Proof, address(mockSP1), callData);
        uint256 vacGas = gasBefore - gasleft();
        console.log("\nStep 7 | verifyAndCall() overhead:", vacGas, "gas");
        console.log("         Result (callCount):", abi.decode(result, (uint256)));
        console.log("         Pattern: verify binius64 proof + atomically call enforce()");

        // ---- Summary ------------------------------------------------------------
        console.log("\n=============================");
        console.log("Path A summary:");
        console.log("  Native Solidity binius verifier: ~71,000,000 gas (L2 only)");
        console.log("  SP1 Groth16 wrapping (estimated): ~", gasOverhead + 220_000 + 15_872 + 21_000, "gas (L1-feasible)");
        uint256 speedup = 71_000_000 / (gasOverhead + 220_000 + 15_872 + 21_000);
        console.log("  Speedup factor: ~", speedup, "x");
        console.log("  ProofVerified event emitted (see logs above).");
        console.log("=============================\n");

        vm.stopBroadcast();
    }
}
