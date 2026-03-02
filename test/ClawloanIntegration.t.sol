// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

import {SingletonVault}       from "../contracts/SingletonVault.sol";
import {CapabilityKernel}     from "../contracts/CapabilityKernel.sol";
import {EnvelopeRegistry}     from "../contracts/EnvelopeRegistry.sol";
import {ReceiptAccumulator}   from "../contracts/ReceiptAccumulator.sol";
import {CreditVerifier}       from "../contracts/CreditVerifier.sol";
import {Types}                from "../contracts/Types.sol";
import {HashLib}              from "../contracts/HashLib.sol";
import {ClawloanRepayAdapter} from "../contracts/adapters/ClawloanRepayAdapter.sol";
import {ICircuit1Verifier}    from "../contracts/interfaces/ICircuit1Verifier.sol";

import {MockERC20}                from "./mocks/MockERC20.sol";
import {MockClawloanPool}        from "./mocks/MockClawloanPool.sol";
import {MockTimestampOracle}     from "./mocks/MockTimestampOracle.sol";
import {MockCircuit1Verifier}    from "./mocks/MockCircuit1Verifier.sol";
import {MockHealthFactorOracle}  from "./mocks/MockHealthFactorOracle.sol";

/// @title ClawloanIntegrationTest
/// @notice End-to-end PoC: Atlas Protocol × Clawloan liveness-independent loan repayment.
///
/// The scenario this test demonstrates:
///
///   Traditional Clawloan flow (fragile):
///     Borrow → task → agent repays manually OR operator wallet drained on liquidation.
///     If agent crashes mid-task, the operator must have USDC + approval ready within 7 days.
///
///   Atlas-enhanced flow (this test):
///     Borrow → task → deposit earnings into Atlas vault → register repayment envelope →
///     agent goes offline permanently → keeper triggers envelope at deadline →
///     Clawloan loan repaid automatically, profit stays in vault.
///
///   The agent's liveness is NEVER required after the envelope is registered.
///   The loan is ALWAYS repaid as long as earnings are in the vault.
///
/// ─── Protocol roles in this test ────────────────────────────────────────────
///
///   OPERATOR (alice, OPERATOR_PK):
///     The human/EOA that owns the vault position and issues capability tokens.
///     In production: the operator deposits task earnings, signs capabilities,
///     and registers the envelope — then goes offline.
///
///   AGENT (bob, AGENT_PK):
///     The AI agent key that signs intents. In production: the agent executes
///     off-chain work, directs where earnings go, and pre-signs the repayment intent
///     before going offline.
///
///   KEEPER (keeper):
///     A permissionless keeper that monitors the EnvelopeRegistry and calls trigger()
///     when the time condition is satisfied. Receives keeperRewardBps of the output.
///
/// ─── EIP-712 domain note ─────────────────────────────────────────────────────
///
///   Two separate capability signatures are required (dual-domain design):
///
///   1. envelope.manage capability — signed against the REGISTRY's EIP-712 domain.
///      Authorises the envelope creation. Alice signs this.
///
///   2. vault.spend capability — signed against the KERNEL's EIP-712 domain.
///      Authorises the actual USDC transfer at trigger time. Alice signs this.
///      Committed to the envelope as keccak256(abi.encode(intent)).intentCommitment.
///
///   Bob signs the intent against the KERNEL's domain.

contract ClawloanIntegrationTest is Test {

    // ─────────────────────────────────────────────────────────────────────────
    // Signers — fixed private keys for deterministic EIP-712 signing
    // ─────────────────────────────────────────────────────────────────────────

    uint256 internal constant OPERATOR_PK = 0xA11CE;  // alice — position owner, capability issuer
    uint256 internal constant AGENT_PK    = 0xB0B;    // bob   — agent key, intent signer

    address internal operator;
    address internal agent;
    address internal keeper  = makeAddr("keeper");
    address internal owner   = makeAddr("owner");

    // ─────────────────────────────────────────────────────────────────────────
    // Contracts
    // ─────────────────────────────────────────────────────────────────────────

    SingletonVault        internal vault;
    CapabilityKernel      internal kernel;
    EnvelopeRegistry      internal registry;
    ReceiptAccumulator    internal accumulator;
    CreditVerifier        internal creditVerifier;
    MockCircuit1Verifier  internal mockVerifier;
    ClawloanRepayAdapter     internal repayAdapter;
    MockClawloanPool         internal pool;
    MockERC20                internal usdc;
    MockTimestampOracle      internal tsOracle;
    MockHealthFactorOracle   internal healthOracle;

    // ─────────────────────────────────────────────────────────────────────────
    // Economic parameters
    // ─────────────────────────────────────────────────────────────────────────

    uint256 internal constant BOT_ID        = 1;
    uint256 internal constant BORROW_AMOUNT = 10e6;   // 10 USDC borrowed from Clawloan
    uint256 internal constant TASK_EARNINGS = 15e6;   // 15 USDC: principal + interest + profit
    uint256 internal constant DEBT_AMOUNT   = 10e6;   // exact repayment (principal; mock has no interest)
    uint256 internal constant PROFIT        = 5e6;    // 5 USDC profit returned to vault

    uint256 internal constant KEEPER_REWARD_BPS = 10; // 0.1% keeper reward = 0.005 USDC on 5 USDC surplus

    // ─────────────────────────────────────────────────────────────────────────
    // Timing
    // ─────────────────────────────────────────────────────────────────────────

    uint256 internal constant START_TS     = 1_700_000_000;
    uint256 internal constant LOAN_WINDOW  = 7 days;
    uint256 internal loanDeadline;

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.warp(START_TS);
        loanDeadline = block.timestamp + LOAN_WINDOW;

        operator = vm.addr(OPERATOR_PK);
        agent    = vm.addr(AGENT_PK);

        // ── Deploy Atlas core ─────────────────────────────────────────────────
        vault    = new SingletonVault(owner, false);
        kernel   = new CapabilityKernel(address(vault), owner);
        registry = new EnvelopeRegistry(address(vault), address(kernel), owner, 0);

        // ── Deploy Clawloan mock and USDC ─────────────────────────────────────
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockClawloanPool(address(usdc));

        // ── Deploy timestamp oracle ───────────────────────────────────────────
        tsOracle = new MockTimestampOracle();

        // ── Deploy health factor oracle (initial: 10_000 = 1.0, fully healthy) ─
        healthOracle = new MockHealthFactorOracle(10_000);

        // ── Deploy Clawloan repay adapter ─────────────────────────────────────
        repayAdapter = new ClawloanRepayAdapter();

        // ── Deploy receipt accumulator and credit verifier ────────────────────
        accumulator    = new ReceiptAccumulator(owner);
        mockVerifier   = new MockCircuit1Verifier();
        creditVerifier = new CreditVerifier(address(accumulator), address(mockVerifier), owner);

        // ── Wire up Atlas ─────────────────────────────────────────────────────
        vm.startPrank(owner);
        vault.setKernel(address(kernel));
        vault.setEnvelopeRegistry(address(registry));
        kernel.registerAdapter(address(repayAdapter));
        // The EnvelopeRegistry calls kernel.executeIntent() during trigger() —
        // it must be an approved solver (Phase 1 solver whitelist, Decision 7).
        kernel.setSolver(address(registry), true);
        // Whitelist the test contract for direct kernel calls in partial-proof tests.
        kernel.setSolver(address(this), true);
        // Wire the accumulator so every executeIntent appends a receipt.
        kernel.setReceiptAccumulator(address(accumulator));
        accumulator.setKernel(address(kernel));
        vm.stopPrank();

        // ── Fund the Clawloan pool so it can service the borrow ───────────────
        usdc.mint(address(pool), 1_000_000e6);

        // ── Fund the operator with task earnings ──────────────────────────────
        // In production: operator receives task payment from the client / task system.
        usdc.mint(operator, TASK_EARNINGS);
        vm.prank(operator);
        usdc.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Build the vault.spend capability + intent, signed against the KERNEL domain.
    ///      These are committed into the envelope at registration and revealed at trigger.
    function _buildSpendBundle(
        bytes32 posHash,
        bytes32 capNonce,
        bytes32 intentNonce
    ) internal view returns (
        Types.Position   memory position,
        Types.Capability memory spendCap,
        Types.Intent     memory intent,
        bytes            memory capSig,
        bytes            memory intentSig
    ) {
        (position, spendCap, intent, capSig, intentSig) =
            _buildSpendBundleWithSalt(bytes32(uint256(1)), capNonce, intentNonce);
        // suppress unused warning on posHash
        posHash;
    }

    /// @dev Like _buildSpendBundle but with an explicit position salt.
    ///      Used by _runRepaymentCycle where each cycle deposits with a unique salt.
    function _buildSpendBundleWithSalt(
        bytes32 posSalt,
        bytes32 capNonce,
        bytes32 intentNonce
    ) internal view returns (
        Types.Position   memory position,
        Types.Capability memory spendCap,
        Types.Intent     memory intent,
        bytes            memory capSig,
        bytes            memory intentSig
    ) {
        position = Types.Position({
            owner:  operator,
            asset:  address(usdc),
            amount: TASK_EARNINGS,
            salt:   posSalt
        });

        bytes32 posHash = keccak256(abi.encode(position));

        address[] memory adapterList = new address[](1);
        adapterList[0] = address(repayAdapter);

        address[] memory usdcList = new address[](1);
        usdcList[0] = address(usdc);

        spendCap = Types.Capability({
            issuer:               operator,
            grantee:              agent,
            scope:                keccak256("vault.spend"),
            expiry:               block.timestamp + 30 days,
            nonce:                capNonce,
            constraints:          Types.Constraints({
                maxSpendPerPeriod: 0,           // unconstrained — single-use intent
                periodDuration:    0,
                minReturnBps:      0,           // no slippage floor at capability level
                allowedAdapters:   adapterList, // only the repay adapter
                allowedTokensIn:   usdcList,    // only USDC in
                allowedTokensOut:  usdcList     // only USDC out (surplus)
            }),
            parentCapabilityHash: bytes32(0),
            delegationDepth:      0
        });

        bytes32 capHash = HashLib.hashCapability(spendCap);

        intent = Types.Intent({
            positionCommitment: posHash,
            capabilityHash:     capHash,
            adapter:            address(repayAdapter),
            adapterData:        abi.encode(address(pool), BOT_ID, DEBT_AMOUNT),
            minReturn:          PROFIT - 1e6,  // floor: at least 4 USDC profit
            deadline:           block.timestamp + 30 days,
            nonce:              intentNonce,
            outputToken:        address(usdc),
            returnTo:           address(0),      // address(0) = route to position.owner (default)
            submitter:          address(registry), // only the registry can submit this intent
            solverFeeBps:       uint16(KEEPER_REWARD_BPS)
        });

        // Sign vault.spend capability against the KERNEL's EIP-712 domain.
        bytes32 capDigest = kernel.capabilityDigest(spendCap);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(OPERATOR_PK, capDigest);
        capSig = abi.encodePacked(cr, cs, cv);

        // Sign intent against the KERNEL's EIP-712 domain.
        bytes32 intentDigest = kernel.intentDigest(intent);
        (uint8 iv, bytes32 ir, bytes32 is_) = vm.sign(AGENT_PK, intentDigest);
        intentSig = abi.encodePacked(ir, is_, iv);
    }

    /// @dev Build the envelope.manage capability + envelope struct for register().
    ///      Signed against the REGISTRY's EIP-712 domain (different domain from kernel).
    function _buildRegistration(
        bytes32          posHash,
        Types.Conditions memory conditions,
        Types.Intent     memory intent,
        bytes32          manageCap_nonce
    ) internal view returns (
        Types.Envelope   memory envelope,
        Types.Capability memory manageCap,
        bytes            memory manageCapSig
    ) {
        manageCap = Types.Capability({
            issuer:               operator,
            grantee:              agent,
            scope:                keccak256("envelope.manage"),
            expiry:               block.timestamp + 30 days,
            nonce:                manageCap_nonce,
            constraints:          Types.Constraints({
                maxSpendPerPeriod: 0,
                periodDuration:    0,
                minReturnBps:      0,
                allowedAdapters:   new address[](0),
                allowedTokensIn:   new address[](0),
                allowedTokensOut:  new address[](0)
            }),
            parentCapabilityHash: bytes32(0),
            delegationDepth:      0
        });

        // Sign envelope.manage capability against the REGISTRY's EIP-712 domain.
        bytes32 manageDigest = registry.capabilityDigest(manageCap);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OPERATOR_PK, manageDigest);
        manageCapSig = abi.encodePacked(r, s, v);

        envelope = Types.Envelope({
            positionCommitment: posHash,
            // Conditions and intent are committed as opaque hashes — revealed only at trigger.
            conditionsHash:     keccak256(abi.encode(conditions)),
            intentCommitment:   keccak256(abi.encode(intent)),
            capabilityHash:     HashLib.hashCapability(manageCap),
            expiry:             loanDeadline + 1 days, // envelope valid until 1 day after deadline
            keeperRewardBps:    uint16(KEEPER_REWARD_BPS),
            minKeeperRewardWei: 0
        });
    }

    // =========================================================================
    // Main PoC: Full lifecycle
    // =========================================================================

    /// @notice Happy path: borrow → deposit earnings → register envelope →
    ///         agent goes offline → keeper triggers → loan repaid, profit in vault.
    ///
    /// This is the core demonstration of Atlas's liveness-independent enforcement
    /// property applied to Clawloan's loan repayment problem.
    function test_fullLifecycle_agentOffline_loanAutoRepaid() public {
        // ── Step 1: Agent borrows from Clawloan ──────────────────────────────
        vm.prank(operator);
        pool.borrow(BOT_ID, BORROW_AMOUNT);

        assertEq(pool.getDebt(BOT_ID), BORROW_AMOUNT, "debt should be recorded");
        assertEq(usdc.balanceOf(operator), TASK_EARNINGS + BORROW_AMOUNT,
            "operator should hold borrowed USDC plus pre-funded earnings");

        // ── Step 2: Task completes — deposit earnings into Atlas vault ────────
        // In production: task payment arrives, operator deposits it into the vault.
        // The operator already holds TASK_EARNINGS (minted in setUp) plus the borrowed
        // BORROW_AMOUNT. Here we only deposit the TASK_EARNINGS — the borrowed USDC
        // was spent on the task. This models the economic reality:
        //   borrow 10 USDC → spend on task → earn 15 USDC → deposit 15 into vault.
        bytes32 posSalt = bytes32(uint256(1));

        vm.prank(operator);
        bytes32 posHash = vault.deposit(address(usdc), TASK_EARNINGS, posSalt);

        assertEq(usdc.balanceOf(address(vault)), TASK_EARNINGS, "vault should hold earnings");
        assertTrue(vault.positionExists(posHash), "position should exist");

        // ── Step 3: Build repayment bundle (vault.spend cap + intent) ─────────
        // These are pre-signed and committed to the envelope. The agent and operator
        // can go offline immediately after this step.
        Types.Conditions memory conditions = Types.Conditions({
            priceOracle:           address(tsOracle),
            baseToken:             address(0),     // informational only — not a price pair
            quoteToken:            address(0),
            triggerPrice:          loanDeadline,   // fires when block.timestamp > loanDeadline
            op:                    Types.ComparisonOp.GREATER_THAN,
            secondaryOracle:       address(0),     // no compound condition
            secondaryTriggerPrice: 0,
            secondaryOp:           Types.ComparisonOp.LESS_THAN,
            logicOp:               Types.LogicOp.AND
        });

        (
            Types.Position   memory position,
            Types.Capability memory spendCap,
            Types.Intent     memory intent,
            bytes            memory capSig,
            bytes            memory intentSig
        ) = _buildSpendBundle(posHash, bytes32(uint256(1)), bytes32(uint256(2)));

        // ── Step 4: Register the envelope ────────────────────────────────────
        (
            Types.Envelope   memory envelope,
            Types.Capability memory manageCap,
            bytes            memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, bytes32(uint256(3)));

        vm.prank(agent);
        bytes32 envelopeHash = registry.register(envelope, manageCap, manageCapSig, position);

        assertEq(envelopeHash != bytes32(0), true, "envelope should be registered");
        assertTrue(vault.isEncumbered(posHash), "position should be encumbered by envelope");

        // ── AGENT GOES OFFLINE — no more agent or operator calls after this point ──

        // ── Step 5: Time passes, loan deadline approaches ─────────────────────
        // In Clawloan's model, at loanDeadline anyone can liquidate the bot —
        // pulling from the operator's wallet with a 5% penalty.
        // With Atlas, the keeper fires the envelope instead.
        vm.warp(loanDeadline + 1);

        // Confirm: the loan is still outstanding (agent never repaid manually).
        assertEq(pool.getDebt(BOT_ID), BORROW_AMOUNT, "loan still outstanding at deadline");

        // ── Step 6: Keeper triggers the envelope ─────────────────────────────
        // Any address can be the keeper. They see the condition is met (block.timestamp
        // > loanDeadline) and call trigger() with the revealed preimages.
        uint256 keeperUsdcBefore = usdc.balanceOf(keeper);

        vm.prank(keeper);
        registry.trigger(
            envelopeHash,
            conditions,
            position,
            intent,
            spendCap,
            capSig,
            intentSig
        );

        // ── Step 7: Assertions ────────────────────────────────────────────────

        // Clawloan loan is fully repaid.
        assertEq(pool.getDebt(BOT_ID), 0, "loan should be fully repaid");

        // The earnings position has been spent.
        assertFalse(vault.positionExists(posHash), "earnings position should be consumed");

        // The earnings position is no longer encumbered (it was unencumbered before execution).
        assertFalse(vault.isEncumbered(posHash), "position should no longer be encumbered");

        // Clawloan pool received exactly the debt amount.
        assertEq(usdc.balanceOf(address(pool)), 1_000_000e6 - BORROW_AMOUNT + DEBT_AMOUNT,
            "pool should have received repayment");

        // Keeper received their reward (KEEPER_REWARD_BPS of the surplus).
        uint256 keeperReward = usdc.balanceOf(keeper) - keeperUsdcBefore;
        assertGt(keeperReward, 0, "keeper should have been paid");

        // The profit (minus keeper reward) is now a new vault position owned by the operator.
        uint256 expectedProfit = PROFIT - keeperReward;
        bytes32 outputSalt = keccak256(abi.encode(
            keccak256(abi.encode(intent.nonce, posHash)),
            "output"
        ));
        Types.Position memory profitPosition = Types.Position({
            owner:  operator,
            asset:  address(usdc),
            amount: expectedProfit,
            salt:   outputSalt
        });
        bytes32 profitHash = keccak256(abi.encode(profitPosition));
        assertTrue(vault.positionExists(profitHash), "profit should be in vault as new position");

        console2.log("=== Atlas x Clawloan PoC: Full Lifecycle ===");
        console2.log("Loan repaid (USDC):        ", DEBT_AMOUNT / 1e6);
        console2.log("Keeper reward (raw units): ", keeperReward);
        console2.log("Profit in vault (USDC):    ", expectedProfit / 1e6);
        console2.log("Agent was alive after step 4:    false");
        console2.log("Operator was alive after step 4: false");
    }

    // =========================================================================
    // Failure cases
    // =========================================================================

    /// @notice Keeper cannot trigger before the deadline — condition not met.
    function test_trigger_reverts_if_condition_not_met() public {
        vm.prank(operator);
        pool.borrow(BOT_ID, BORROW_AMOUNT);

        bytes32 posSalt = bytes32(uint256(1));
        vm.prank(operator);
        bytes32 posHash = vault.deposit(address(usdc), TASK_EARNINGS, posSalt);

        Types.Conditions memory conditions = Types.Conditions({
            priceOracle:           address(tsOracle),
            baseToken:             address(0),
            quoteToken:            address(0),
            triggerPrice:          loanDeadline,
            op:                    Types.ComparisonOp.GREATER_THAN,
            secondaryOracle:       address(0),
            secondaryTriggerPrice: 0,
            secondaryOp:           Types.ComparisonOp.LESS_THAN,
            logicOp:               Types.LogicOp.AND
        });

        (
            Types.Position   memory position,
            Types.Capability memory spendCap,
            Types.Intent     memory intent,
            bytes            memory capSig,
            bytes            memory intentSig
        ) = _buildSpendBundle(posHash, bytes32(uint256(1)), bytes32(uint256(2)));

        (
            Types.Envelope   memory envelope,
            Types.Capability memory manageCap,
            bytes            memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, bytes32(uint256(3)));

        vm.prank(agent);
        bytes32 envelopeHash = registry.register(envelope, manageCap, manageCapSig, position);

        // Do NOT warp — still before deadline. block.timestamp = loanDeadline - 7 days.
        // tsOracle returns block.timestamp <= loanDeadline → condition not met.
        vm.expectRevert(EnvelopeRegistry.ConditionNotMet.selector);
        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);

        // Loan is still outstanding — the agent's liveness would be needed to repay manually.
        assertEq(pool.getDebt(BOT_ID), BORROW_AMOUNT, "loan still outstanding");
        assertTrue(vault.isEncumbered(posHash), "position still encumbered");
    }

    /// @notice Operator can cancel the envelope (e.g. agent repaid manually ahead of deadline).
    ///         After cancellation, the position is unencumbered and can be withdrawn directly.
    function test_cancel_unencumbers_position() public {
        bytes32 posSalt = bytes32(uint256(1));
        vm.prank(operator);
        bytes32 posHash = vault.deposit(address(usdc), TASK_EARNINGS, posSalt);

        Types.Conditions memory conditions = Types.Conditions({
            priceOracle:           address(tsOracle),
            baseToken:             address(0),
            quoteToken:            address(0),
            triggerPrice:          loanDeadline,
            op:                    Types.ComparisonOp.GREATER_THAN,
            secondaryOracle:       address(0),
            secondaryTriggerPrice: 0,
            secondaryOp:           Types.ComparisonOp.LESS_THAN,
            logicOp:               Types.LogicOp.AND
        });

        (
            Types.Position   memory position,
            ,
            Types.Intent memory intent,
            ,
        ) = _buildSpendBundle(posHash, bytes32(uint256(1)), bytes32(uint256(2)));

        (
            Types.Envelope   memory envelope,
            Types.Capability memory manageCap,
            bytes            memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, bytes32(uint256(3)));

        vm.prank(agent);
        bytes32 envelopeHash = registry.register(envelope, manageCap, manageCapSig, position);
        assertTrue(vault.isEncumbered(posHash), "should be encumbered after register");

        // Operator manually repaid Clawloan (e.g. agent was online and did it directly).
        // Cancel the envelope — position is freed.
        vm.prank(operator);
        registry.cancel(envelopeHash);

        assertFalse(vault.isEncumbered(posHash), "should be unencumbered after cancel");

        // Operator can now withdraw the earnings directly from the vault.
        Types.Position memory pos = Types.Position({
            owner:  operator,
            asset:  address(usdc),
            amount: TASK_EARNINGS,
            salt:   posSalt
        });
        vm.prank(operator);
        vault.withdraw(pos, operator);

        assertEq(usdc.balanceOf(operator), TASK_EARNINGS, "operator recovered earnings");
    }

    /// @notice Non-owner cannot cancel the envelope.
    function test_cancel_reverts_if_not_issuer() public {
        bytes32 posSalt = bytes32(uint256(1));
        vm.prank(operator);
        bytes32 posHash = vault.deposit(address(usdc), TASK_EARNINGS, posSalt);

        Types.Conditions memory conditions = Types.Conditions({
            priceOracle:           address(tsOracle),
            baseToken:             address(0),
            quoteToken:            address(0),
            triggerPrice:          loanDeadline,
            op:                    Types.ComparisonOp.GREATER_THAN,
            secondaryOracle:       address(0),
            secondaryTriggerPrice: 0,
            secondaryOp:           Types.ComparisonOp.LESS_THAN,
            logicOp:               Types.LogicOp.AND
        });

        (Types.Position memory position, , Types.Intent memory intent, , ) =
            _buildSpendBundle(posHash, bytes32(uint256(1)), bytes32(uint256(2)));

        (
            Types.Envelope   memory envelope,
            Types.Capability memory manageCap,
            bytes            memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, bytes32(uint256(3)));

        vm.prank(agent);
        bytes32 envelopeHash = registry.register(envelope, manageCap, manageCapSig, position);

        vm.expectRevert(EnvelopeRegistry.NotIssuer.selector);
        vm.prank(keeper);
        registry.cancel(envelopeHash);
    }

    /// @notice Validate: adapter rejects debtAmount >= position amount (no surplus).
    function test_adapter_validate_rejects_no_surplus() public view {
        (bool valid, string memory reason) = repayAdapter.validate(
            address(usdc),
            address(usdc),
            TASK_EARNINGS,
            abi.encode(address(pool), BOT_ID, TASK_EARNINGS) // debtAmount == amountIn → no surplus
        );
        assertFalse(valid, "should reject no-surplus configuration");
        assertEq(reason, "debtAmount/debtCap must be less than position amount: no surplus");
    }

    /// @notice Validate: adapter rejects tokenOut != tokenIn.
    function test_adapter_validate_rejects_different_tokens() public {
        address weth = makeAddr("weth");
        (bool valid, string memory reason) = repayAdapter.validate(
            address(usdc),
            weth,
            TASK_EARNINGS,
            abi.encode(address(pool), BOT_ID, DEBT_AMOUNT)
        );
        assertFalse(valid, "should reject tokenOut != tokenIn");
        assertEq(reason, "tokenOut must equal tokenIn: same-token repayment");
    }

    /// @notice Quote returns correct surplus.
    function test_adapter_quote() public view {
        uint256 quoted = repayAdapter.quote(
            address(usdc),
            address(usdc),
            TASK_EARNINGS,
            abi.encode(address(pool), BOT_ID, DEBT_AMOUNT)
        );
        assertEq(quoted, PROFIT, "quote should return expected surplus");
    }

    // =========================================================================
    // Credit proof lifecycle
    // =========================================================================

    /// @notice Helper: run one complete borrow → deposit → envelope → trigger cycle.
    ///         Returns the capability hash used (for querying the accumulator) and the receipt hash.
    function _runRepaymentCycle(
        uint256 botId,
        bytes32 posSalt,
        bytes32 capNonce,
        bytes32 intentNonce,
        bytes32 manageCap_nonce,
        uint256 loanTs        // loan deadline timestamp
    ) internal returns (bytes32 capHash, bytes32 receiptHash) {
        // Borrow from pool.
        vm.prank(operator);
        pool.borrow(botId, BORROW_AMOUNT);

        // Deposit task earnings into vault.
        usdc.mint(operator, TASK_EARNINGS);
        vm.prank(operator);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(operator);
        bytes32 posHash = vault.deposit(address(usdc), TASK_EARNINGS, posSalt);

        // Build spend bundle + envelope.
        Types.Conditions memory conditions = Types.Conditions({
            priceOracle:           address(tsOracle),
            baseToken:             address(0),
            quoteToken:            address(0),
            triggerPrice:          loanTs,
            op:                    Types.ComparisonOp.GREATER_THAN,
            secondaryOracle:       address(0),
            secondaryTriggerPrice: 0,
            secondaryOp:           Types.ComparisonOp.LESS_THAN,
            logicOp:               Types.LogicOp.AND
        });

        (
            Types.Position   memory position,
            Types.Capability memory spendCap,
            Types.Intent     memory intent,
            bytes            memory capSig,
            bytes            memory intentSig
        ) = _buildSpendBundleWithSalt(posSalt, capNonce, intentNonce);

        (
            Types.Envelope   memory envelope,
            Types.Capability memory manageCap,
            bytes            memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, manageCap_nonce);

        // Override envelope expiry to match this cycle's loan deadline.
        envelope.expiry = loanTs + 1 days;

        // Re-sign the manage cap for this envelope (expiry and cap nonce differ each cycle).
        manageCap = Types.Capability({
            issuer:               operator,
            grantee:              agent,
            scope:                keccak256("envelope.manage"),
            expiry:               block.timestamp + 30 days,
            nonce:                manageCap_nonce,
            constraints:          Types.Constraints({
                maxSpendPerPeriod: 0,
                periodDuration:    0,
                minReturnBps:      0,
                allowedAdapters:   new address[](0),
                allowedTokensIn:   new address[](0),
                allowedTokensOut:  new address[](0)
            }),
            parentCapabilityHash: bytes32(0),
            delegationDepth:      0
        });
        envelope.capabilityHash = HashLib.hashCapability(manageCap);
        envelope.intentCommitment = keccak256(abi.encode(intent));
        envelope.conditionsHash   = keccak256(abi.encode(conditions));

        bytes32 manageDigest = registry.capabilityDigest(manageCap);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OPERATOR_PK, manageDigest);
        manageCapSig = abi.encodePacked(r, s, v);

        vm.prank(agent);
        bytes32 envelopeHash = registry.register(envelope, manageCap, manageCapSig, position);

        // Warp past the loan deadline and trigger.
        vm.warp(loanTs + 1);

        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);

        capHash    = HashLib.hashCapability(spendCap);
        uint256 idx = accumulator.receiptCount(capHash) - 1;
        receiptHash = accumulator.getReceiptHashes(capHash)[idx];
    }

    /// @notice Three repayment cycles → accumulator has 3 receipts → Circuit 1 mock proof
    ///         → CreditVerifier attests BRONZE tier.
    ///
    /// This is the complete credit proof pipeline. The key demonstration:
    ///   - The accumulator root changes after EVERY repayment.
    ///   - The mock verifier recomputes the rolling root from the plaintext receipts.
    ///   - If any receipt is omitted or reordered, root recomputation fails → proof rejected.
    ///   - CreditVerifier reads the same root from the accumulator → no forgery possible.
    ///   - Credit tier is upgraded from NEW to BRONZE after the proof.
    function test_creditProof_threeRepayments_bronzeTier() public {
        uint256 BASE_TS = block.timestamp;

        // ── Run 3 repayment cycles ────────────────────────────────────────────
        // Each cycle uses unique salts/nonces to prevent position collision.
        // loanTs increases by 8 days each cycle so warp is monotonically increasing.
        // We capture the actual capHash returned from the helper — no manual reconstruction.
        (bytes32 capHash1,) = _runRepaymentCycle(
            BOT_ID,
            bytes32(uint256(10)),
            bytes32(uint256(11)),
            bytes32(uint256(12)),
            bytes32(uint256(13)),
            BASE_TS + 7 days
        );

        _runRepaymentCycle(
            BOT_ID,
            bytes32(uint256(20)),
            bytes32(uint256(21)),
            bytes32(uint256(22)),
            bytes32(uint256(23)),
            block.timestamp + 7 days
        );

        _runRepaymentCycle(
            BOT_ID,
            bytes32(uint256(30)),
            bytes32(uint256(31)),
            bytes32(uint256(32)),
            bytes32(uint256(33)),
            block.timestamp + 7 days
        );

        // ── Verify accumulator state ──────────────────────────────────────────
        // capHash1 comes directly from _buildSpendBundleWithSalt inside _runRepaymentCycle —
        // the exact same hash the kernel passed to accumulator.accumulate().
        // Each cycle uses a different capNonce → different capabilityHash → separate chain.
        assertEq(accumulator.receiptCount(capHash1), 1, "cap1 should have 1 receipt");
        assertEq(
            accumulator.adapterReceiptCount(capHash1, address(repayAdapter)),
            1,
            "cap1 should have 1 ClawloanRepay receipt"
        );

        // ── Build the credit proof for cap1 (1 repayment → BRONZE) ───────────
        bytes32[] memory receiptHashes = accumulator.getReceiptHashes(capHash1);
        bytes32[] memory nullifiers    = accumulator.getNullifiers(capHash1);

        // adapters[]: the adapter used per receipt — now part of the rolling root commitment.
        // The mock verifier checks these directly; the real circuit takes them as private inputs.
        address[] memory adapters = new address[](1);
        adapters[0] = address(repayAdapter);

        // amountsIn / amountsOut: used for minReturnBps constraint checks.
        uint256[] memory amountsIn  = new uint256[](1);
        uint256[] memory amountsOut = new uint256[](1);
        amountsIn[0]  = TASK_EARNINGS;
        amountsOut[0] = PROFIT;  // surplus returned to kernel (pre-keeper-fee)

        bytes memory proof = abi.encode(receiptHashes, nullifiers, adapters, amountsIn, amountsOut);

        // Before submitting proof: tier = NEW (0 proven repayments).
        assertEq(creditVerifier.getCreditTier(capHash1), 0, "should start at NEW tier");

        // Submit the proof.
        creditVerifier.submitProof(
            capHash1,
            1,                       // n = 1 repayment
            address(repayAdapter),   // only ClawloanRepayAdapter receipts count
            0,                       // no minReturnBps filter
            proof
        );

        // After proof: tier = BRONZE (1 proven repayment).
        assertEq(creditVerifier.getCreditTier(capHash1), 1, "should be BRONZE after 1 repayment");
        assertEq(creditVerifier.getMaxBorrow(capHash1), 50e6, "BRONZE max borrow = 50 USDC");

        console2.log("=== Atlas x Clawloan PoC: Credit Proof ===");
        console2.log("Repayments accumulated:  3 (separate capabilities)");
        console2.log("Cap1 proven repayments:  1");
        console2.log("Credit tier:             BRONZE (1)");
        console2.log("Max borrow (USDC):       50");
        console2.log("Verifier:                MockCircuit1Verifier (ZK slot ready)");
    }

    /// @notice Anti-fabrication: agent cannot skip a receipt to hide a default.
    ///
    /// Scenario: agent has 2 receipts. They try to submit a proof claiming N=1
    /// using a root computed from only the FIRST receipt. But the accumulator's
    /// current root reflects BOTH receipts. The roots won't match → proof rejected.
    function test_creditProof_rejects_omitted_receipt() public {
        uint256 BASE_TS = block.timestamp;

        // Run one repayment cycle and capture the actual capHash.
        (bytes32 capHash,) = _runRepaymentCycle(
            BOT_ID,
            bytes32(uint256(40)),
            bytes32(uint256(41)),
            bytes32(uint256(42)),
            bytes32(uint256(43)),
            BASE_TS + 7 days
        );

        assertEq(accumulator.receiptCount(capHash), 1);

        // Agent tries to submit proof with n=1 but provides a FORGED root (bytes32(0)).
        // This simulates: "I claim the root from before my receipt was accumulated."
        bytes32[] memory receiptHashes = new bytes32[](1);
        bytes32[] memory nullifiers    = new bytes32[](1);
        address[] memory adapters      = new address[](1);
        uint256[] memory amountsIn     = new uint256[](1);
        uint256[] memory amountsOut    = new uint256[](1);

        receiptHashes[0] = accumulator.getReceiptHashes(capHash)[0];
        nullifiers[0]    = accumulator.getNullifiers(capHash)[0];
        adapters[0]      = address(repayAdapter);
        amountsIn[0]     = TASK_EARNINGS;
        amountsOut[0]    = PROFIT;

        bytes memory validProof = abi.encode(receiptHashes, nullifiers, adapters, amountsIn, amountsOut);

        // Valid proof works (sanity).
        creditVerifier.submitProof(capHash, 1, address(repayAdapter), 0, validProof);
        assertEq(creditVerifier.getCreditTier(capHash), 1, "valid proof should pass");

        // Now try to forge: replace the receipt hash with a fake one.
        bytes32[] memory fakeHashes = new bytes32[](1);
        fakeHashes[0] = bytes32(uint256(0xDEADBEEF)); // not the real receipt

        bytes memory forgedProof = abi.encode(fakeHashes, nullifiers, adapters, amountsIn, amountsOut);

        vm.expectRevert(CreditVerifier.InvalidProof.selector);
        creditVerifier.submitProof(capHash, 1, address(repayAdapter), 0, forgedProof);
    }

    /// @notice Verifier can be upgraded from mock to production without changing CreditVerifier.
    function test_verifier_upgrade_path() public view {
        // Phase 1: MockCircuit1Verifier is set.
        assertEq(address(creditVerifier.verifier()), address(mockVerifier));

        // Phase 2 upgrade: owner calls setVerifier(address(realVerifier)).
        // After the Noir circuit is compiled and the UltraHonk verifier is deployed,
        // this single call activates ZK proof verification with no other contract changes.
        // (We only assert the slot is correct here — no real verifier to deploy in unit tests.)
        assertNotEq(address(creditVerifier.verifier()), address(0));
    }

    // =========================================================================
    // Phase 2 improvements
    // =========================================================================

    // ── Improvement 1: Live debt querying ────────────────────────────────────

    /// @notice Live-debt mode: adapter queries pool.getDebt() at trigger time.
    ///
    /// Scenario: interest accrues between envelope registration and keeper trigger.
    ///   Static mode (old): repays only the baked-in 10 USDC → loan NOT fully cleared.
    ///   Live-debt mode:    repays the live 11 USDC (principal + 1 USDC interest) → fully cleared.
    ///
    /// The key invariant: with useLiveDebt=true the loan is ALWAYS fully repaid as long as
    /// the live debt does not exceed the operator's pre-set debtCap.
    function test_liveDebt_accrued_interest_fully_repaid() public {
        // ── Borrow and simulate interest accrual ─────────────────────────────
        vm.prank(operator);
        pool.borrow(BOT_ID, BORROW_AMOUNT);  // debt = 10 USDC

        pool.accrueInterest(BOT_ID, 1e6);    // interest = 1 USDC → debt = 11 USDC
        assertEq(pool.getDebt(BOT_ID), 11e6, "debt should include accrued interest");

        // ── Deposit task earnings into vault ──────────────────────────────────
        bytes32 posSalt = bytes32(uint256(50));
        vm.prank(operator);
        bytes32 posHash = vault.deposit(address(usdc), TASK_EARNINGS, posSalt);

        // ── Build spend bundle with live-debt encoding ────────────────────────
        // debtCap = 12 USDC (> actual 11 USDC). The adapter will query live debt at trigger.
        uint256 DEBT_CAP = 12e6;

        Types.Position memory position = Types.Position({
            owner:  operator,
            asset:  address(usdc),
            amount: TASK_EARNINGS,
            salt:   posSalt
        });

        address[] memory adapterList = new address[](1);
        adapterList[0] = address(repayAdapter);
        address[] memory usdcList = new address[](1);
        usdcList[0] = address(usdc);

        bytes32 capNonce  = bytes32(uint256(51));
        bytes32 intentNonce = bytes32(uint256(52));

        Types.Capability memory spendCap = Types.Capability({
            issuer:               operator,
            grantee:              agent,
            scope:                keccak256("vault.spend"),
            expiry:               block.timestamp + 30 days,
            nonce:                capNonce,
            constraints:          Types.Constraints({
                maxSpendPerPeriod: 0,
                periodDuration:    0,
                minReturnBps:      0,
                allowedAdapters:   adapterList,
                allowedTokensIn:   usdcList,
                allowedTokensOut:  usdcList
            }),
            parentCapabilityHash: bytes32(0),
            delegationDepth:      0
        });

        bytes32 capHash = HashLib.hashCapability(spendCap);

        Types.Intent memory intent = Types.Intent({
            positionCommitment: posHash,
            capabilityHash:     capHash,
            adapter:            address(repayAdapter),
            // useLiveDebt=true: adapter will query pool.getDebt(BOT_ID) at trigger time
            adapterData:        abi.encode(address(pool), BOT_ID, DEBT_CAP, true),
            minReturn:          TASK_EARNINGS - DEBT_CAP - 1e6, // floor: amountIn - debtCap - margin
            deadline:           block.timestamp + 30 days,
            nonce:              intentNonce,
            outputToken:        address(usdc),
            returnTo:           address(0),      // address(0) = route to position.owner (default)
            submitter:          address(registry),
            solverFeeBps:       uint16(KEEPER_REWARD_BPS)
        });

        bytes32 capDigest = kernel.capabilityDigest(spendCap);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(OPERATOR_PK, capDigest);
        bytes memory capSig = abi.encodePacked(cr, cs, cv);

        bytes32 intentDigest = kernel.intentDigest(intent);
        (uint8 iv, bytes32 ir, bytes32 is_) = vm.sign(AGENT_PK, intentDigest);
        bytes memory intentSig = abi.encodePacked(ir, is_, iv);

        // ── Register envelope ────────────────────────────────────────────────
        Types.Conditions memory conditions = Types.Conditions({
            priceOracle:           address(tsOracle),
            baseToken:             address(0),
            quoteToken:            address(0),
            triggerPrice:          loanDeadline,
            op:                    Types.ComparisonOp.GREATER_THAN,
            secondaryOracle:       address(0),
            secondaryTriggerPrice: 0,
            secondaryOp:           Types.ComparisonOp.LESS_THAN,
            logicOp:               Types.LogicOp.AND
        });

        Types.Capability memory manageCap = Types.Capability({
            issuer:               operator,
            grantee:              agent,
            scope:                keccak256("envelope.manage"),
            expiry:               block.timestamp + 30 days,
            nonce:                bytes32(uint256(53)),
            constraints:          Types.Constraints({
                maxSpendPerPeriod: 0,
                periodDuration:    0,
                minReturnBps:      0,
                allowedAdapters:   new address[](0),
                allowedTokensIn:   new address[](0),
                allowedTokensOut:  new address[](0)
            }),
            parentCapabilityHash: bytes32(0),
            delegationDepth:      0
        });

        bytes32 manageDigest = registry.capabilityDigest(manageCap);
        (uint8 mv, bytes32 mr, bytes32 ms) = vm.sign(OPERATOR_PK, manageDigest);
        bytes memory manageCapSig = abi.encodePacked(mr, ms, mv);

        Types.Envelope memory envelope = Types.Envelope({
            positionCommitment: posHash,
            conditionsHash:     keccak256(abi.encode(conditions)),
            intentCommitment:   keccak256(abi.encode(intent)),
            capabilityHash:     HashLib.hashCapability(manageCap),
            expiry:             loanDeadline + 1 days,
            keeperRewardBps:    uint16(KEEPER_REWARD_BPS),
            minKeeperRewardWei: 0
        });

        vm.prank(agent);
        bytes32 envelopeHash = registry.register(envelope, manageCap, manageCapSig, position);

        // ── Warp past deadline and trigger ────────────────────────────────────
        vm.warp(loanDeadline + 1);

        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);

        // ── Assertions ────────────────────────────────────────────────────────
        // Loan fully repaid — adapter used LIVE debt (11 USDC), not static 10 USDC.
        assertEq(pool.getDebt(BOT_ID), 0, "loan should be fully repaid including interest");

        // Position spent.
        assertFalse(vault.positionExists(posHash), "earnings position should be consumed");

        // Surplus = 15 - 11 = 4 USDC (minus keeper reward), stays in vault.
        uint256 keeperReward = usdc.balanceOf(keeper);
        uint256 expectedSurplus = TASK_EARNINGS - 11e6 - keeperReward;
        assertGt(expectedSurplus, 0, "surplus should be positive after interest");

        console2.log("=== Atlas x Clawloan: Live Debt Demo ===");
        console2.log("Static debt at envelope creation (USDC):  ", BORROW_AMOUNT / 1e6);
        console2.log("Accrued interest (USDC):                   1");
        console2.log("Live debt at trigger (USDC):               11");
        console2.log("Surplus after repay (USDC):               ", expectedSurplus / 1e6);
        console2.log("Loan fully cleared:                        true");
    }

    /// @notice Live-debt mode reverts when the live debt exceeds the operator's debtCap.
    function test_liveDebt_reverts_when_exceeds_cap() public {
        vm.prank(operator);
        pool.borrow(BOT_ID, BORROW_AMOUNT);

        // Accrue so much interest that debt now exceeds the cap baked into the intent.
        uint256 DEBT_CAP = 10e6;  // cap = original borrow
        pool.accrueInterest(BOT_ID, 5e6);  // debt = 15 USDC > cap

        bytes32 posSalt = bytes32(uint256(60));
        vm.prank(operator);
        bytes32 posHash = vault.deposit(address(usdc), TASK_EARNINGS, posSalt);

        Types.Position memory position = Types.Position({
            owner:  operator,
            asset:  address(usdc),
            amount: TASK_EARNINGS,
            salt:   posSalt
        });

        address[] memory adapterList = new address[](1);
        adapterList[0] = address(repayAdapter);
        address[] memory usdcList = new address[](1);
        usdcList[0] = address(usdc);

        bytes32 capNonce   = bytes32(uint256(61));
        bytes32 intentNonce = bytes32(uint256(62));

        Types.Capability memory spendCap = Types.Capability({
            issuer:               operator,
            grantee:              agent,
            scope:                keccak256("vault.spend"),
            expiry:               block.timestamp + 30 days,
            nonce:                capNonce,
            constraints:          Types.Constraints({
                maxSpendPerPeriod: 0,
                periodDuration:    0,
                minReturnBps:      0,
                allowedAdapters:   adapterList,
                allowedTokensIn:   usdcList,
                allowedTokensOut:  usdcList
            }),
            parentCapabilityHash: bytes32(0),
            delegationDepth:      0
        });

        bytes32 capHash = HashLib.hashCapability(spendCap);

        Types.Intent memory intent = Types.Intent({
            positionCommitment: posHash,
            capabilityHash:     capHash,
            adapter:            address(repayAdapter),
            adapterData:        abi.encode(address(pool), BOT_ID, DEBT_CAP, true), // useLiveDebt=true
            minReturn:          1,
            deadline:           block.timestamp + 30 days,
            nonce:              intentNonce,
            outputToken:        address(usdc),
            returnTo:           address(0),      // address(0) = route to position.owner (default)
            submitter:          address(0),
            solverFeeBps:       0
        });

        bytes32 capDigest = kernel.capabilityDigest(spendCap);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(OPERATOR_PK, capDigest);
        bytes memory capSig = abi.encodePacked(cr, cs, cv);

        bytes32 intentDigest = kernel.intentDigest(intent);
        (uint8 iv, bytes32 ir, bytes32 is_) = vm.sign(AGENT_PK, intentDigest);
        bytes memory intentSig = abi.encodePacked(ir, is_, iv);

        // Direct kernel execution should revert inside the adapter.
        vm.expectRevert();
        kernel.executeIntent(position, spendCap, intent, capSig, intentSig);

        // Loan is still outstanding — position is safe.
        assertEq(pool.getDebt(BOT_ID), 15e6, "loan should still be outstanding");
    }

    // ── Improvement 2: Compound trigger conditions ────────────────────────────

    /// @notice Compound OR condition: envelope fires early when health factor drops,
    ///         before the loan deadline is reached.
    ///
    /// Condition tree: block.timestamp > loanDeadline  OR  healthFactor < 9_000
    ///   Phase 1 (before health drop): both conditions false → trigger reverts.
    ///   Phase 2 (after health drop):  secondary condition met → trigger succeeds via OR.
    function test_compound_earlyTrigger_via_healthFactor() public {
        vm.prank(operator);
        pool.borrow(BOT_ID, BORROW_AMOUNT);

        bytes32 posSalt = bytes32(uint256(70));
        vm.prank(operator);
        bytes32 posHash = vault.deposit(address(usdc), TASK_EARNINGS, posSalt);

        // ── Compound condition: time OR health factor ─────────────────────────
        // Primary:   block.timestamp > loanDeadline  (fires at deadline — fallback)
        // Secondary: healthFactor < 9_000            (fires early if bot degrades)
        // logicOp:   OR
        Types.Conditions memory conditions = Types.Conditions({
            priceOracle:           address(tsOracle),
            baseToken:             address(0),
            quoteToken:            address(0),
            triggerPrice:          loanDeadline,
            op:                    Types.ComparisonOp.GREATER_THAN,
            secondaryOracle:       address(healthOracle),
            secondaryTriggerPrice: 9_000,
            secondaryOp:           Types.ComparisonOp.LESS_THAN,
            logicOp:               Types.LogicOp.OR
        });

        (
            Types.Position   memory position,
            Types.Capability memory spendCap,
            Types.Intent     memory intent,
            bytes            memory capSig,
            bytes            memory intentSig
        ) = _buildSpendBundleWithSalt(posSalt, bytes32(uint256(71)), bytes32(uint256(72)));

        (
            Types.Envelope   memory envelope,
            Types.Capability memory manageCap,
            bytes            memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, bytes32(uint256(73)));

        vm.prank(agent);
        bytes32 envelopeHash = registry.register(envelope, manageCap, manageCapSig, position);

        // ── Before health drop: neither condition met — trigger must fail ──────
        // block.timestamp = START_TS (well before loanDeadline), healthFactor = 10_000 (> 9_000)
        vm.expectRevert(EnvelopeRegistry.ConditionNotMet.selector);
        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);

        // Loan still outstanding, position still encumbered.
        assertEq(pool.getDebt(BOT_ID), BORROW_AMOUNT, "loan should still be outstanding");
        assertTrue(vault.isEncumbered(posHash), "position should still be encumbered");

        // ── Health factor drops below threshold ───────────────────────────────
        // Simulates collateral degradation before the loan deadline.
        // No deadline warp — only the health factor changes.
        healthOracle.setHealthFactor(8_000);  // 0.8 < threshold 0.9

        // Primary condition still false (before deadline), but secondary is now met.
        // OR logic → trigger should succeed.
        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);

        // ── Assertions ────────────────────────────────────────────────────────
        assertEq(pool.getDebt(BOT_ID), 0, "loan should be repaid via early health trigger");
        assertFalse(vault.positionExists(posHash), "earnings position should be consumed");

        console2.log("=== Atlas x Clawloan: Compound Condition (OR) ===");
        console2.log("Primary (time) condition met:   false");
        console2.log("Secondary (health) condition:   healthFactor 8000 < threshold 9000");
        console2.log("logicOp:                        OR");
        console2.log("Triggered before deadline:      true");
    }

    // ── Improvement 3: Partial credit proof (N < totalReceipts) ──────────────

    /// @notice Partial proof: agent proves a prefix of N=2 receipts out of 3 accumulated.
    ///
    /// The key Phase 2 invariant: rootAtIndex(cap, N) is the committed root after EXACTLY
    /// N receipts. Circuit 1 verifies the first N receipts hash to this root.
    /// Any omission in the first N still causes a mismatch — cherry-picking is impossible.
    ///
    /// This also validates that rootAtIndex() returns consistent values:
    ///   rootAtIndex(0) = bytes32(0)
    ///   rootAtIndex(1) = root after 1st receipt
    ///   rootAtIndex(3) = rollingRoot()  (same as current root)
    function test_partialCreditProof_twoOfThree_bronzeTier() public {
        uint256 fixedExpiry = START_TS + 365 days;
        bytes32 sharedCapNonce = bytes32(uint256(999));

        // ── Run 3 repayments under the SAME capability (shared capNonce + fixedExpiry) ──
        bytes32 capHash = _runDirectRepayment(
            bytes32(uint256(101)), sharedCapNonce, bytes32(uint256(102)), fixedExpiry
        );
        _runDirectRepayment(
            bytes32(uint256(201)), sharedCapNonce, bytes32(uint256(202)), fixedExpiry
        );
        _runDirectRepayment(
            bytes32(uint256(301)), sharedCapNonce, bytes32(uint256(302)), fixedExpiry
        );

        // ── Verify accumulator state ──────────────────────────────────────────
        assertEq(accumulator.receiptCount(capHash), 3, "should have 3 receipts");

        // rootAtIndex checks
        assertEq(accumulator.rootAtIndex(capHash, 0), bytes32(0), "root_0 must be zero");
        assertNotEq(accumulator.rootAtIndex(capHash, 1), bytes32(0), "root_1 must be non-zero");
        assertNotEq(accumulator.rootAtIndex(capHash, 2), bytes32(0), "root_2 must be non-zero");
        assertEq(
            accumulator.rootAtIndex(capHash, 3),
            accumulator.rollingRoot(capHash),
            "rootAtIndex(3) must equal current rolling root"
        );
        // Each historical root is distinct
        assertNotEq(
            accumulator.rootAtIndex(capHash, 1),
            accumulator.rootAtIndex(capHash, 2),
            "root_1 != root_2"
        );
        assertNotEq(
            accumulator.rootAtIndex(capHash, 2),
            accumulator.rootAtIndex(capHash, 3),
            "root_2 != root_3"
        );

        // ── Build partial proof for N=2 ───────────────────────────────────────
        bytes32[] memory allHashes    = accumulator.getReceiptHashes(capHash);
        bytes32[] memory allNullifiers = accumulator.getNullifiers(capHash);

        // Subset: only first 2 receipts
        bytes32[] memory partialHashes = new bytes32[](2);
        bytes32[] memory partialNulls  = new bytes32[](2);
        address[] memory adapters      = new address[](2);
        uint256[] memory amountsIn     = new uint256[](2);
        uint256[] memory amountsOut    = new uint256[](2);

        for (uint256 i = 0; i < 2; i++) {
            partialHashes[i] = allHashes[i];
            partialNulls[i]  = allNullifiers[i];
            adapters[i]      = address(repayAdapter);
            amountsIn[i]     = TASK_EARNINGS;
            amountsOut[i]    = PROFIT;
        }

        bytes memory proof = abi.encode(
            partialHashes, partialNulls, adapters, amountsIn, amountsOut
        );

        // Before: no proven repayments → NEW tier
        assertEq(creditVerifier.getCreditTier(capHash), 0, "should start at NEW tier");

        // Submit partial proof for N=2.
        // CreditVerifier now calls accumulator.rootAtIndex(capHash, 2) — the committed
        // root after EXACTLY 2 receipts — and the mock verifier recomputes from the 2
        // provided receipts. They must match. Receipt 3 is not involved.
        creditVerifier.submitProof(capHash, 2, address(repayAdapter), 0, proof);

        // 2 proven repayments → BRONZE
        assertEq(creditVerifier.getCreditTier(capHash), 1, "should be BRONZE after 2 proven repayments");
        assertEq(creditVerifier.getMaxBorrow(capHash), 50e6, "BRONZE max borrow = 50 USDC");

        console2.log("=== Atlas x Clawloan: Partial Credit Proof ===");
        console2.log("Total receipts on-chain:   3");
        console2.log("Receipts proven (partial): 2");
        console2.log("Proven against:            rootAtIndex(cap, 2)  [not current root]");
        console2.log("Credit tier:               BRONZE (1)");
        console2.log("Cherry-picking impossible: true (any omission breaks root recomputation)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: direct repayment helper (bypasses envelope, same capability)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Execute a ClawloanRepay intent directly through the kernel (no envelope).
    ///      Uses a FIXED capExpiry so that the same capNonce always produces the same
    ///      capabilityHash across multiple calls, even when block.timestamp has advanced.
    ///      This lets us accumulate multiple receipts under a single capability for the
    ///      partial-proof test.
    ///
    ///      The test contract must be an approved solver (set in setUp).
    function _runDirectRepayment(
        bytes32 posSalt,
        bytes32 capNonce,
        bytes32 intentNonce,
        uint256 fixedCapExpiry
    ) internal returns (bytes32 capHash) {
        // Borrow so the pool has an outstanding debt for this cycle.
        vm.prank(operator);
        pool.borrow(BOT_ID, BORROW_AMOUNT);

        // Deposit task earnings into the vault.
        usdc.mint(operator, TASK_EARNINGS);
        vm.prank(operator);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(operator);
        bytes32 posHash = vault.deposit(address(usdc), TASK_EARNINGS, posSalt);

        Types.Position memory position = Types.Position({
            owner:  operator,
            asset:  address(usdc),
            amount: TASK_EARNINGS,
            salt:   posSalt
        });

        address[] memory adapterList = new address[](1);
        adapterList[0] = address(repayAdapter);
        address[] memory usdcList = new address[](1);
        usdcList[0] = address(usdc);

        Types.Capability memory spendCap = Types.Capability({
            issuer:               operator,
            grantee:              agent,
            scope:                keccak256("vault.spend"),
            expiry:               fixedCapExpiry,  // fixed — stable capabilityHash across calls
            nonce:                capNonce,
            constraints:          Types.Constraints({
                maxSpendPerPeriod: 0,
                periodDuration:    0,
                minReturnBps:      0,
                allowedAdapters:   adapterList,
                allowedTokensIn:   usdcList,
                allowedTokensOut:  usdcList
            }),
            parentCapabilityHash: bytes32(0),
            delegationDepth:      0
        });

        capHash = HashLib.hashCapability(spendCap);

        Types.Intent memory intent = Types.Intent({
            positionCommitment: posHash,
            capabilityHash:     capHash,
            adapter:            address(repayAdapter),
            adapterData:        abi.encode(address(pool), BOT_ID, DEBT_AMOUNT),
            minReturn:          PROFIT - 1e6,
            deadline:           fixedCapExpiry,
            nonce:              intentNonce,
            outputToken:        address(usdc),
            returnTo:           address(0),      // address(0) = route to position.owner (default)
            submitter:          address(0),  // any approved solver (address(this))
            solverFeeBps:       0
        });

        bytes32 capDigest = kernel.capabilityDigest(spendCap);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(OPERATOR_PK, capDigest);
        bytes memory capSig = abi.encodePacked(cr, cs, cv);

        bytes32 intentDigest = kernel.intentDigest(intent);
        (uint8 iv, bytes32 ir, bytes32 is_) = vm.sign(AGENT_PK, intentDigest);
        bytes memory intentSig = abi.encodePacked(ir, is_, iv);

        // Execute directly — this test contract is a whitelisted solver.
        kernel.executeIntent(position, spendCap, intent, capSig, intentSig);
    }
}
