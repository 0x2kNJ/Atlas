// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {SingletonVault} from "../contracts/SingletonVault.sol";
import {CapabilityKernel} from "../contracts/CapabilityKernel.sol";
import {EnvelopeRegistry} from "../contracts/EnvelopeRegistry.sol";

/// @title Deploy
/// @notice Full Atlas Protocol Phase 1 deployment.
///
/// Usage:
///   # Dry-run (no broadcast):
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL -vvvv
///
///   # Live deployment:
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast \
///     --private-key $DEPLOYER_PK --verify --etherscan-api-key $ETHERSCAN_KEY
///
/// Environment variables:
///   DEPLOYER_PK                    Private key of the deployer.
///   ATLAS_OWNER                    Admin/owner address (multisig or deployer).
///   ATLAS_PROTOCOL_MIN_KEEPER_WEI  Protocol-level keeper reward floor (default 0).
///   ATLAS_ALLOWLIST_TOKENS         Comma-separated token addresses to allowlist (optional).
///
/// Deployment order:
///   1. SingletonVault    — no dependencies
///   2. CapabilityKernel  — depends on vault
///   3. EnvelopeRegistry  — depends on vault + kernel
///   4. Wire vault        — setKernel + setEnvelopeRegistry (once, then ownership transfer)
///
/// After deployment, the deployer calls:
///   vault.transferOwnership(ATLAS_OWNER)
///   kernel.transferOwnership(ATLAS_OWNER)
///   registry.transferOwnership(ATLAS_OWNER)
///
/// The new owner must call acceptOwnership() on each contract (Ownable2Step).

contract Deploy is Script {

    // ─────────────────────────────────────────────────────────────────────────
    // Deployment outputs (for downstream use / verification)
    // ─────────────────────────────────────────────────────────────────────────

    SingletonVault   public vault;
    CapabilityKernel public kernel;
    EnvelopeRegistry public registry;

    function run() external {
        // ── Read config from environment ─────────────────────────────────────
        address owner    = vm.envOr("ATLAS_OWNER", msg.sender);
        uint128 minFloor = uint128(vm.envOr("ATLAS_PROTOCOL_MIN_KEEPER_WEI", uint256(0)));

        console2.log("=== Atlas Protocol - Phase 1 Deployment ===");
        console2.log("Owner:        ", owner);
        console2.log("MinKeeperWei: ", minFloor);
        console2.log("Chain ID:     ", block.chainid);
        console2.log("Deployer:     ", msg.sender);
        console2.log("");

        vm.startBroadcast();

        // ── 1. SingletonVault ─────────────────────────────────────────────────
        // tokenAllowlist = false — allowlist is managed post-deploy by owner.
        vault = new SingletonVault(msg.sender, false);
        console2.log("SingletonVault:  ", address(vault));

        // ── 2. CapabilityKernel ───────────────────────────────────────────────
        kernel = new CapabilityKernel(address(vault), msg.sender);
        console2.log("CapabilityKernel:", address(kernel));

        // ── 3. EnvelopeRegistry ───────────────────────────────────────────────
        registry = new EnvelopeRegistry(
            address(vault),
            address(kernel),
            msg.sender,
            minFloor
        );
        console2.log("EnvelopeRegistry:", address(registry));

        // ── 4. Wire vault ─────────────────────────────────────────────────────
        // These calls are one-time: both functions revert if called again.
        vault.setKernel(address(kernel));
        vault.setEnvelopeRegistry(address(registry));
        console2.log("Vault wired to kernel + registry");

        // ── 5. Transfer ownership to intended owner ───────────────────────────
        // Ownable2Step: ownership is pending until owner calls acceptOwnership().
        if (owner != msg.sender) {
            vault.transferOwnership(owner);
            kernel.transferOwnership(owner);
            registry.transferOwnership(owner);
            console2.log("Ownership pending transfer to: ", owner);
            console2.log("Owner must call acceptOwnership() on each contract.");
        } else {
            console2.log("Owner == deployer, no transfer needed.");
        }

        vm.stopBroadcast();

        // ── Print deployment summary ─────────────────────────────────────────
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("SingletonVault:   ", address(vault));
        console2.log("CapabilityKernel: ", address(kernel));
        console2.log("EnvelopeRegistry: ", address(registry));
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Owner calls acceptOwnership() on each contract.");
        console2.log("  2. Owner registers adapter contracts via kernel.registerAdapter().");
        console2.log("  3. Owner optionally enables the token allowlist and adds tokens.");
        console2.log("  4. Set protocolMinKeeperRewardWei if > 0 isn't appropriate for this chain.");
    }
}
