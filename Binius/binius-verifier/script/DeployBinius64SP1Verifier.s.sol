// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/Binius64SP1Verifier.sol";

/// @title DeployBinius64SP1Verifier
/// @notice Deployment script for Binius64SP1Verifier.sol.
///
/// The two required constructor args are passed as environment variables
/// or fall back to known defaults.
///
///   SP1_VERIFIER_ADDR  — address of the SP1VerifierGateway on the target network
///   BINIUS64_VKEY      — bytes32 vkey hash of the compiled binius64 guest program
///
/// Get BINIUS64_VKEY by running:
///   cd sp1-guest && cargo run --bin prove -- vkey
///
/// Current BINIUS64_VKEY (guest program v0.1.0, circuit_id security-fix):
///   0x00c8508697673f052b007f80dadec4ea96d520efc69aaf7ab7d322e0eb60d868
///
/// Mainnet SP1VerifierGateway (from docs.succinct.xyz):
///   Ethereum / Arbitrum / Base / Optimism:
///     0x397A5f7f3dBd538f23DE225B51f532c34448dA9B  (same CREATE2 address)
///   Sepolia:
///     0x3B6041173B80E77f038f3F2C0f9744f04837185e
///
/// Usage:
///   # Simulate (no broadcast)
///   forge script script/DeployBinius64SP1Verifier.s.sol --rpc-url $RPC_URL -vvvv
///
///   # Broadcast to Sepolia
///   forge script script/DeployBinius64SP1Verifier.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL \
///     --private-key $DEPLOYER_KEY \
///     --broadcast \
///     --verify \
///     --etherscan-api-key $ETHERSCAN_KEY
///
///   # Register initial circuits after deployment (one-time setup):
///   cast send <DEPLOYED_ADDR> 'registerCircuit(bytes32)' <CIRCUIT_ID> --private-key $DEPLOYER_KEY
///   cast send <DEPLOYED_ADDR> 'setCircuitRegistryEnabled(bool)' true --private-key $DEPLOYER_KEY

contract DeployBinius64SP1Verifier is Script {

    // Known SP1VerifierGateway addresses
    address constant SP1_GATEWAY_MAINNET  = 0x397A5f7f3dBd538f23DE225B51f532c34448dA9B;
    address constant SP1_GATEWAY_SEPOLIA  = 0x3B6041173B80E77f038f3F2C0f9744f04837185e;

    // Default vkey — update when the guest program changes.
    // Recompute: cd sp1-guest && cargo run --bin prove -- vkey
    bytes32 constant DEFAULT_VKEY =
        0x00c8508697673f052b007f80dadec4ea96d520efc69aaf7ab7d322e0eb60d868;

    function run() external returns (address deployed) {
        address sp1Verifier = _readSP1Verifier();
        bytes32 binius64VKey = _readVKey();

        console.log("=== Deploying Binius64SP1Verifier ===");
        console.log("Network chain id: %s", block.chainid);
        console.log("SP1 Verifier:     %s", sp1Verifier);
        console.log("Binius64 VKey:    %s", vm.toString(binius64VKey));
        console.log("");

        vm.startBroadcast();
        Binius64SP1Verifier verifier = new Binius64SP1Verifier(sp1Verifier, binius64VKey);
        vm.stopBroadcast();

        deployed = address(verifier);
        console.log("Deployed to:    %s", deployed);
        console.log("Owner:          %s (= deployer)", msg.sender);
        console.log("Registry:       disabled (permissionless by default)");
        console.log("");
        console.log("=== Post-deployment setup ===");
        console.log("# Enable circuit registry and register your circuits:");
        console.log("cast send %s 'registerCircuit(bytes32)' <CIRCUIT_ID> --private-key $DEPLOYER_KEY", deployed);
        console.log("cast send %s 'setCircuitRegistryEnabled(bool)' true --private-key $DEPLOYER_KEY", deployed);
        console.log("");
        console.log("# Submit a proof (after generating with cargo run --bin prove -- prove):");
        console.log("cast send %s 'verify(bytes,bytes)' <publicValues> <sp1ProofBytes>", deployed);
        console.log("");
        console.log("# Verify on Etherscan:");
        console.log("forge verify-contract %s src/Binius64SP1Verifier.sol:Binius64SP1Verifier \\", deployed);
        console.log("  --constructor-args $(cast abi-encode 'f(address,bytes32)' %s %s)",
            sp1Verifier, vm.toString(binius64VKey));
    }

    function _readSP1Verifier() internal view returns (address) {
        try vm.envAddress("SP1_VERIFIER_ADDR") returns (address addr) {
            return addr;
        } catch {
            if (block.chainid == 1 || block.chainid == 8453 || block.chainid == 42161 || block.chainid == 10) {
                return SP1_GATEWAY_MAINNET;
            } else if (block.chainid == 11155111) {
                return SP1_GATEWAY_SEPOLIA;
            }
            revert("Set SP1_VERIFIER_ADDR env var for this network");
        }
    }

    function _readVKey() internal view returns (bytes32) {
        try vm.envBytes32("BINIUS64_VKEY") returns (bytes32 vkey) {
            return vkey;
        } catch {
            // Fall back to the known default rather than reverting —
            // makes simulation (`forge script` without env vars) work out of the box.
            console.log("BINIUS64_VKEY not set -- using default (guest v0.1.0)");
            return DEFAULT_VKEY;
        }
    }
}
