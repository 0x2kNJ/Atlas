// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CapabilityKernel} from "../contracts/CapabilityKernel.sol";
import {UniswapV3Adapter} from "../contracts/adapters/UniswapV3Adapter.sol";
import {AaveV3Adapter} from "../contracts/adapters/AaveV3Adapter.sol";

/// @title RegisterAdapters
/// @notice Deploy and register the UniswapV3 and AaveV3 adapters on an already-deployed kernel.
///
/// Usage:
///   forge script script/RegisterAdapters.s.sol --rpc-url $RPC_URL --broadcast \
///     --private-key $DEPLOYER_PK --verify --etherscan-api-key $ETHERSCAN_KEY
///
/// Environment variables:
///   ATLAS_KERNEL          Address of the deployed CapabilityKernel.
///   UNISWAP_V3_ROUTER     Uniswap V3 SwapRouter02 address.
///   UNISWAP_V3_QUOTER     Uniswap V3 QuoterV2 address.
///   AAVE_V3_ADDRESSES_PROVIDER  Aave V3 PoolAddressesProvider address.

contract RegisterAdapters is Script {

    function run() external {
        address kernelAddr = vm.envAddress("ATLAS_KERNEL");
        address uniRouter  = vm.envAddress("UNISWAP_V3_ROUTER");
        address uniQuoter  = vm.envAddress("UNISWAP_V3_QUOTER");
        address aaveProvider = vm.envAddress("AAVE_V3_ADDRESSES_PROVIDER");

        CapabilityKernel kernel = CapabilityKernel(kernelAddr);

        console2.log("=== Registering Adapters ===");
        console2.log("Kernel:         ", kernelAddr);
        console2.log("AaveProvider:   ", aaveProvider);

        vm.startBroadcast();

        // ── UniswapV3Adapter ─────────────────────────────────────────────────
        UniswapV3Adapter uniAdapter = new UniswapV3Adapter(uniRouter, uniQuoter);
        console2.log("UniswapV3Adapter:", address(uniAdapter));
        kernel.registerAdapter(address(uniAdapter));
        console2.log("Registered UniswapV3Adapter");

        // ── AaveV3Adapter ─────────────────────────────────────────────────────
        AaveV3Adapter aaveAdapter = new AaveV3Adapter(aaveProvider);
        console2.log("AaveV3Adapter:   ", address(aaveAdapter));
        kernel.registerAdapter(address(aaveAdapter));
        console2.log("Registered AaveV3Adapter");

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Adapter Registration Summary ===");
        console2.log("UniswapV3Adapter:", address(uniAdapter));
        console2.log("AaveV3Adapter:   ", address(aaveAdapter));
    }
}
