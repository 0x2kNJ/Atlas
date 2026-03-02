// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {SingletonVault}       from "../contracts/SingletonVault.sol";
import {CapabilityKernel}     from "../contracts/CapabilityKernel.sol";
import {EnvelopeRegistry}     from "../contracts/EnvelopeRegistry.sol";
import {ReceiptAccumulator}   from "../contracts/ReceiptAccumulator.sol";
import {CreditVerifier}       from "../contracts/CreditVerifier.sol";
import {ClawloanRepayAdapter} from "../contracts/adapters/ClawloanRepayAdapter.sol";
import {DirectTransferAdapter} from "../contracts/adapters/DirectTransferAdapter.sol";
import {PriceSwapAdapter}     from "../contracts/adapters/PriceSwapAdapter.sol";
import {LiquidationAdapter}        from "../contracts/adapters/LiquidationAdapter.sol";
import {MockReverseSwapAdapter}    from "../contracts/adapters/MockReverseSwapAdapter.sol";
import {PoolPauseAdapter}          from "../contracts/adapters/PoolPauseAdapter.sol";
import {UtilisationOracle}         from "../contracts/oracles/UtilisationOracle.sol";

import {MockERC20}              from "../test/mocks/MockERC20.sol";
import {MockClawloanPool}       from "../test/mocks/MockClawloanPool.sol";
import {MockTimestampOracle}    from "../test/mocks/MockTimestampOracle.sol";
import {MockCircuit1Verifier}   from "../test/mocks/MockCircuit1Verifier.sol";
import {MockSubAgentHub}        from "../test/mocks/MockSubAgentHub.sol";
import {MockPriceOracle}        from "../test/mocks/MockPriceOracle.sol";
import {MockHealthOracle}       from "../test/mocks/MockHealthOracle.sol";
import {MockAavePool}           from "../test/mocks/MockAavePool.sol";
import {MockCreditGatedLender}  from "../test/mocks/MockCreditGatedLender.sol";
import {MockConsensusHub}       from "../test/mocks/MockConsensusHub.sol";
import {MockCapitalPool}        from "../test/mocks/MockCapitalPool.sol";

/// @title DeployClawloanDemo
/// @notice Deploys the full Atlas × Clawloan PoC stack on a local Anvil node.
///
/// Deploys:
///   - MockERC20 (USDC, 6 decimals)
///   - MockClawloanPool
///   - MockTimestampOracle
///   - SingletonVault
///   - CapabilityKernel
///   - EnvelopeRegistry
///   - ReceiptAccumulator
///   - MockCircuit1Verifier
///   - CreditVerifier
///   - ClawloanRepayAdapter  ← registered on the kernel
///
/// Usage:
///   # Start Anvil
///   anvil
///
///   # Deploy (separate terminal)
///   forge script script/DeployClawloanDemo.s.sol \
///     --rpc-url http://127.0.0.1:8545 \
///     --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
/// The script prints every deployed address. Copy them to interact via cast or a frontend.
///
/// To verify the lifecycle without a keeper bot, run the integration test against Anvil:
///   forge test --match-path "test/ClawloanIntegration.t.sol" -vv

contract DeployClawloanDemo is Script {

    // Anvil default account 0 — only used as default owner when ATLAS_OWNER is not set.
    address internal constant ANVIL_ACCOUNT_0 =
        0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function run() external {
        address owner = vm.envOr("ATLAS_OWNER", ANVIL_ACCOUNT_0);

        console2.log("=== Atlas x Clawloan PoC - Local Deployment ===");
        console2.log("Owner:    ", owner);
        console2.log("Chain ID: ", block.chainid);
        console2.log("Deployer: ", msg.sender);
        console2.log("");

        vm.startBroadcast();

        // ── Mock tokens and pool ──────────────────────────────────────────────
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        console2.log("MockUSDC:            ", address(usdc));

        MockClawloanPool pool = new MockClawloanPool(address(usdc));
        console2.log("MockClawloanPool:    ", address(pool));

        // Fund the pool so borrow() can service requests.
        usdc.mint(address(pool), 1_000_000e6);
        console2.log("Pool funded:          1,000,000 USDC");

        // ── Timestamp oracle ─────────────────────────────────────────────────
        MockTimestampOracle tsOracle = new MockTimestampOracle();
        console2.log("MockTimestampOracle: ", address(tsOracle));

        // ── Atlas core ────────────────────────────────────────────────────────
        // tokenAllowlist = false — no allowlist enforced for the PoC.
        SingletonVault vault = new SingletonVault(msg.sender, false);
        console2.log("SingletonVault:      ", address(vault));

        CapabilityKernel kernel = new CapabilityKernel(address(vault), msg.sender);
        console2.log("CapabilityKernel:    ", address(kernel));

        EnvelopeRegistry registry = new EnvelopeRegistry(
            address(vault),
            address(kernel),
            msg.sender,
            0   // no minimum keeper reward floor for local demo
        );
        console2.log("EnvelopeRegistry:    ", address(registry));

        // ── Receipt accumulator + credit verifier ─────────────────────────────
        ReceiptAccumulator accumulator = new ReceiptAccumulator(msg.sender);
        console2.log("ReceiptAccumulator:  ", address(accumulator));

        MockCircuit1Verifier mockVerifier = new MockCircuit1Verifier();
        console2.log("MockCircuit1Verifier:", address(mockVerifier));

        CreditVerifier creditVerifier = new CreditVerifier(
            address(accumulator),
            address(mockVerifier),
            msg.sender
        );
        console2.log("CreditVerifier:      ", address(creditVerifier));

        // ── Clawloan repay adapter ────────────────────────────────────────────
        ClawloanRepayAdapter repayAdapter = new ClawloanRepayAdapter();
        console2.log("ClawloanRepayAdapter:", address(repayAdapter));

        // ── Phase 2: DirectTransferAdapter (Dead Man's Switch) ────────────────
        DirectTransferAdapter dmsAdapter = new DirectTransferAdapter();
        console2.log("DirectTransferAdapter:", address(dmsAdapter));

        // ── Phase 3: MockSubAgentHub (3,000 USDC orchestrator budget) ─────────
        MockSubAgentHub subAgentHub = new MockSubAgentHub(3_000e6);  // nonce 12
        console2.log("MockSubAgentHub:      ", address(subAgentHub));

        // ── Phase 4: Stop-Loss / Protective Put ──────────────────────────────
        // nonce 13: MockWETH — synthetic ETH token for the stop-loss scenario
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        console2.log("MockWETH:             ", address(weth));

        // nonce 14: MockPriceOracle — settable ETH/USD price feed
        MockPriceOracle priceOracle = new MockPriceOracle();  // init at $2,500
        console2.log("MockPriceOracle:      ", address(priceOracle));

        // nonce 15: PriceSwapAdapter — WETH→USDC swap at oracle price
        PriceSwapAdapter swapAdapter = new PriceSwapAdapter(
            address(priceOracle),
            address(usdc),
            address(weth)
        );
        console2.log("PriceSwapAdapter:     ", address(swapAdapter));

        // ── Phase 5: Protocol Liquidation Engine ─────────────────────────────
        // nonce 16: MockHealthOracle — settable health factor feed
        MockHealthOracle healthOracle = new MockHealthOracle();  // init at 2.0
        console2.log("MockHealthOracle:     ", address(healthOracle));

        // nonce 17: MockAavePool — tracks collateral/debt per user
        MockAavePool aavePool = new MockAavePool();
        console2.log("MockAavePool:         ", address(aavePool));

        // nonce 18: LiquidationAdapter — seize collateral, repay debt to pool
        LiquidationAdapter liqAdapter = new LiquidationAdapter();
        console2.log("LiquidationAdapter:   ", address(liqAdapter));

        // ── Phase 6: ZK Credit Passport ──────────────────────────────────────
        // nonce 19: MockCreditGatedLender — tier-gated lending across protocols
        MockCreditGatedLender creditLender = new MockCreditGatedLender(
            address(creditVerifier),
            address(usdc)
        );
        console2.log("MockCreditGatedLender:", address(creditLender));

        // ── Phase 7: M-of-N Consensus ─────────────────────────────────────────
        // nonce 20: MockConsensusHub — collects M-of-N agent approvals
        MockConsensusHub consensusHub = new MockConsensusHub();
        console2.log("MockConsensusHub:     ", address(consensusHub));

        // ── Capital Provider Pool (lender-side ClawLoan) ─────────────────────
        // nonce 21: MockCapitalPool — institutional lender deposits, yield, utilization guard
        MockCapitalPool capitalPool = new MockCapitalPool(address(usdc));
        console2.log("MockCapitalPool:      ", address(capitalPool));

        // nonce 22: UtilisationOracle — Chainlink-compatible oracle wrapping pool utilisation
        UtilisationOracle utilisationOracle = new UtilisationOracle(address(capitalPool));
        console2.log("UtilisationOracle:    ", address(utilisationOracle));

        // nonce 23: PoolPauseAdapter — IAdapter that pauses pool when keeper envelope fires
        PoolPauseAdapter poolPauseAdapter = new PoolPauseAdapter();
        console2.log("PoolPauseAdapter:     ", address(poolPauseAdapter));

        // ── Phase 8: Chained Strategy Graph ──────────────────────────────────
        // nonce 24: MockReverseSwapAdapter — USDC→WETH rebuy at oracle price
        MockReverseSwapAdapter reverseSwapAdapter = new MockReverseSwapAdapter(
            address(priceOracle),
            address(usdc),
            address(weth)
        );
        console2.log("MockReverseSwapAdapter:", address(reverseSwapAdapter));

        // ── Seed liquidity ───────────────────────────────────────────────────
        // Seed PriceSwapAdapter with USDC reserves (funds the WETH→USDC output side).
        usdc.mint(address(swapAdapter), 500_000e6);
        console2.log("PriceSwapAdapter funded: 500,000 USDC");

        // Seed MockReverseSwapAdapter with WETH reserves (funds the USDC→WETH rebuy side).
        weth.mint(address(reverseSwapAdapter), 500e18);
        console2.log("MockReverseSwapAdapter funded: 500 WETH");

        // Seed MockCreditGatedLender with USDC (funds cross-protocol loans).
        usdc.mint(address(creditLender), 100_000e6);
        console2.log("MockCreditGatedLender funded: 100,000 USDC");

        // ── Wire Atlas ────────────────────────────────────────────────────────
        // vault: set kernel and registry (one-time, both revert if called again)
        vault.setKernel(address(kernel));
        vault.setEnvelopeRegistry(address(registry));

        // kernel: register adapters and approve the registry as a solver
        kernel.registerAdapter(address(repayAdapter));
        kernel.registerAdapter(address(dmsAdapter));
        kernel.registerAdapter(address(swapAdapter));
        kernel.registerAdapter(address(liqAdapter));
        kernel.registerAdapter(address(reverseSwapAdapter));
        kernel.registerAdapter(address(poolPauseAdapter));
        // Allow the deployer (Anvil account 0) to call executeIntent directly.
        // This enables the "Publish the Key" and M-of-N demos to submit intents
        // without going through the registry's envelope path.
        kernel.setSolver(address(registry), true);
        kernel.setSolver(ANVIL_ACCOUNT_0, true);

        // accumulator: wire to kernel so every executeIntent appends a receipt
        kernel.setReceiptAccumulator(address(accumulator));
        accumulator.setKernel(address(kernel));

        console2.log("Atlas wired: vault <-> kernel <-> registry <-> accumulator");

        // ── Transfer ownership if a separate owner was specified ─────────────
        if (owner != msg.sender) {
            vault.transferOwnership(owner);
            kernel.transferOwnership(owner);
            registry.transferOwnership(owner);
            accumulator.transferOwnership(owner);
            creditVerifier.transferOwnership(owner);
            console2.log("Ownership pending transfer to:", owner);
            console2.log("Owner must call acceptOwnership() on each contract.");
        } else {
            console2.log("Owner == deployer, no transfer needed.");
        }

        vm.stopBroadcast();

        // ── Deployment summary ────────────────────────────────────────────────
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("--- Phase 1: Core Atlas ---");
        console2.log("MockUSDC:             ", address(usdc));
        console2.log("MockClawloanPool:     ", address(pool));
        console2.log("MockTimestampOracle:  ", address(tsOracle));
        console2.log("SingletonVault:       ", address(vault));
        console2.log("CapabilityKernel:     ", address(kernel));
        console2.log("EnvelopeRegistry:     ", address(registry));
        console2.log("ReceiptAccumulator:   ", address(accumulator));
        console2.log("MockCircuit1Verifier: ", address(mockVerifier));
        console2.log("CreditVerifier:       ", address(creditVerifier));
        console2.log("ClawloanRepayAdapter: ", address(repayAdapter));
        console2.log("--- Phase 2: Dead Man's Switch ---");
        console2.log("DirectTransferAdapter:", address(dmsAdapter));
        console2.log("--- Phase 3: Sub-agent Orchestration ---");
        console2.log("MockSubAgentHub:      ", address(subAgentHub));
        console2.log("--- Phase 4: Stop-Loss / Protective Put ---");
        console2.log("MockWETH:             ", address(weth));
        console2.log("MockPriceOracle:      ", address(priceOracle));
        console2.log("PriceSwapAdapter:     ", address(swapAdapter));
        console2.log("--- Phase 5: Protocol Liquidation Engine ---");
        console2.log("MockHealthOracle:     ", address(healthOracle));
        console2.log("MockAavePool:         ", address(aavePool));
        console2.log("LiquidationAdapter:   ", address(liqAdapter));
        console2.log("--- Phase 6: ZK Credit Passport ---");
        console2.log("MockCreditGatedLender:", address(creditLender));
        console2.log("--- Phase 7: M-of-N Consensus ---");
        console2.log("MockConsensusHub:     ", address(consensusHub));
        console2.log("--- Capital Provider (Lend tab) ---");
        console2.log("MockCapitalPool:      ", address(capitalPool));
        console2.log("UtilisationOracle:    ", address(utilisationOracle));
        console2.log("PoolPauseAdapter:     ", address(poolPauseAdapter));
        console2.log("--- Phase 8: Chained Strategy Graph ---");
        console2.log("MockReverseSwapAdapter:", address(reverseSwapAdapter));
        console2.log("");
        console2.log("=== Next Steps ===");
        console2.log("1. Mint USDC to your operator address:");
        console2.log("   cast send <MockUSDC> 'mint(address,uint256)' <operator> 15000000 --private-key <pk>");
        console2.log("2. Approve vault for USDC:");
        console2.log("   cast send <MockUSDC> 'approve(address,uint256)' <vault> 115792...max --private-key <pk>");
        console2.log("3. Borrow from pool:");
        console2.log("   cast send <MockClawloanPool> 'borrow(uint256,uint256)' 1 10000000 --private-key <pk>");
        console2.log("4. Deposit earnings into vault:");
        console2.log("   cast send <SingletonVault> 'deposit(address,uint256,bytes32)' <usdc> 15000000 <salt>");
        console2.log("5. Run the full integration test suite to verify:");
        console2.log("   forge test --match-path test/ClawloanIntegration.t.sol -vv");
    }
}
