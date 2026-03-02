// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {CapabilityKernel} from "../contracts/CapabilityKernel.sol";
import {SingletonVault} from "../contracts/SingletonVault.sol";
import {Types} from "../contracts/Types.sol";
import {HashLib} from "../contracts/HashLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";

/// @notice Tests for CapabilityKernel.
///
/// Coverage:
///   executeIntent — all 18 verification steps (happy path + each failure)
///   Solver fee    — deduction, payment to solver, net output committed
///   minReturnBps  — capability-level slippage floor
///   Period limit  — accumulation across calls, period boundary reset
///   Double-spend  — nullifier re-use rejected
///   Revocation    — revokeCapability blocks future execution
///   Admin         — registerAdapter, removeAdapter, pause/unpause
///   Fuzz          — signature replay resistance, period accumulation

contract CapabilityKernelTest is Test {

    // -------------------------------------------------------------------------
    // Signers — fixed private keys so we can sign EIP-712 messages off-chain
    // -------------------------------------------------------------------------

    uint256 internal constant ALICE_PK = 0xA11CE;  // issuer / position owner
    uint256 internal constant BOB_PK   = 0xB0B;    // grantee / agent

    address internal alice;
    address internal bob;
    address internal solver = makeAddr("solver");
    address internal owner  = makeAddr("owner");

    // -------------------------------------------------------------------------
    // Contracts
    // -------------------------------------------------------------------------

    SingletonVault internal vault;
    CapabilityKernel internal kernel;
    MockAdapter internal adapter;
    MockERC20 internal usdc;  // tokenIn
    MockERC20 internal weth;  // tokenOut

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    bytes32 internal constant SALT_1 = bytes32(uint256(1));
    bytes32 internal constant SALT_2 = bytes32(uint256(2));

    uint256 internal constant AMOUNT      = 1_000e6;   // 1000 USDC
    uint256 internal constant MOCK_OUTPUT = 5e17;      // 0.5 WETH

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        alice = vm.addr(ALICE_PK);
        bob   = vm.addr(BOB_PK);

        vault  = new SingletonVault(owner, false);
        kernel = new CapabilityKernel(address(vault), owner);

        vm.startPrank(owner);
        vault.setKernel(address(kernel));
        vm.stopPrank();

        adapter = new MockAdapter();
        vm.startPrank(owner);
        kernel.registerAdapter(address(adapter));
        kernel.setSolver(solver, true);
        kernel.setSolver(address(this), true); // test contract calls executeIntent directly
        vm.stopPrank();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Pre-fund alice and give vault approval.
        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        // Pre-load adapter with WETH so it can return output on each execute() call.
        weth.mint(address(adapter), 1_000e18);
        adapter.setMockAmountOut(MOCK_OUTPUT);
    }

    // =========================================================================
    // Test fixture helpers
    // =========================================================================

    /// @dev Returns a default valid capability. All constraints unconstrained.
    function _defaultCap() internal view returns (Types.Capability memory) {
        return Types.Capability({
            issuer:               alice,
            grantee:              bob,
            scope:                keccak256("vault.spend"),
            expiry:               block.timestamp + 1 days,
            nonce:                SALT_1,
            constraints:          _noConstraints(),
            parentCapabilityHash: bytes32(0),
            delegationDepth:      0
        });
    }

    function _noConstraints() internal pure returns (Types.Constraints memory) {
        return Types.Constraints({
            maxSpendPerPeriod: 0,
            periodDuration:    0,
            minReturnBps:      0,
            allowedAdapters:   new address[](0),
            allowedTokensIn:   new address[](0),
            allowedTokensOut:  new address[](0)
        });
    }

    /// @dev Signs and returns a valid (position, cap, intent, capSig, intentSig) bundle.
    ///      Deposits the position into the vault.
    function _buildBundle(
        Types.Capability memory cap,
        bytes32 intentNonce,
        address submitter,
        uint16 solverFeeBps
    ) internal returns (
        Types.Position memory position,
        Types.Intent memory intent,
        bytes memory capSig,
        bytes memory intentSig
    ) {
        position = Types.Position({
            owner:  alice,
            asset:  address(usdc),
            amount: AMOUNT,
            salt:   SALT_1
        });
        bytes32 posHash = keccak256(abi.encode(position));

        // Deposit into vault.
        vm.prank(alice);
        vault.deposit(address(usdc), AMOUNT, SALT_1);

        bytes32 capHash = HashLib.hashCapability(cap);

        intent = Types.Intent({
            positionCommitment: posHash,
            capabilityHash:     capHash,
            adapter:            address(adapter),
            adapterData:        bytes(""),
            minReturn:          MOCK_OUTPUT,
            deadline:           block.timestamp + 1 hours,
            nonce:              intentNonce,
            outputToken:        address(weth),
            returnTo:           address(0),      // address(0) = route to position.owner (default)
            submitter:          submitter,
            solverFeeBps:       solverFeeBps
        });

        // Sign capability (alice = issuer).
        bytes32 capDigest = kernel.capabilityDigest(cap);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(ALICE_PK, capDigest);
        capSig = abi.encodePacked(cr, cs, cv);

        // Sign intent (bob = grantee).
        bytes32 intentDigest_ = kernel.intentDigest(intent);
        (uint8 iv, bytes32 ir, bytes32 is_) = vm.sign(BOB_PK, intentDigest_);
        intentSig = abi.encodePacked(ir, is_, iv);
    }

    /// @dev Convenience: build with defaults.
    function _buildDefault() internal returns (
        Types.Position memory position,
        Types.Capability memory cap,
        Types.Intent memory intent,
        bytes memory capSig,
        bytes memory intentSig
    ) {
        cap = _defaultCap();
        (position, intent, capSig, intentSig) = _buildBundle(cap, SALT_1, address(0), 0);
    }

    // =========================================================================
    // Happy path
    // =========================================================================

    function test_executeIntent_succeeds() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        vm.prank(solver);
        bytes32 receipt = kernel.executeIntent(pos, cap, intent, capSig, intentSig);

        assertTrue(receipt != bytes32(0));
    }

    function test_executeIntent_spendsNullifier() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        bytes32 nullifier = keccak256(abi.encode(intent.nonce, intent.positionCommitment));
        assertFalse(kernel.isSpent(nullifier));

        vm.prank(solver);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);

        assertTrue(kernel.isSpent(nullifier));
    }

    function test_executeIntent_releasesInputPosition() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        bytes32 posHash = intent.positionCommitment;
        assertTrue(vault.positionExists(posHash));

        vm.prank(solver);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);

        assertFalse(vault.positionExists(posHash));
    }

    function test_executeIntent_createsOutputPosition() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        bytes32 nullifier  = keccak256(abi.encode(intent.nonce, intent.positionCommitment));
        bytes32 outputSalt = keccak256(abi.encode(nullifier, "output"));
        bytes32 expectedOut = keccak256(abi.encode(Types.Position({
            owner:  alice,
            asset:  address(weth),
            amount: MOCK_OUTPUT,
            salt:   outputSalt
        })));

        vm.prank(solver);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);

        assertTrue(vault.positionExists(expectedOut));
    }

    function test_executeIntent_emitsIntentExecuted() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        bytes32 nullifier  = keccak256(abi.encode(intent.nonce, intent.positionCommitment));
        bytes32 outputSalt = keccak256(abi.encode(nullifier, "output"));
        bytes32 outHash    = keccak256(abi.encode(Types.Position({
            owner: alice, asset: address(weth), amount: MOCK_OUTPUT, salt: outputSalt
        })));

        vm.expectEmit(true, true, true, true);
        emit CapabilityKernel.IntentExecuted(
            nullifier, intent.positionCommitment, outHash, solver,
            address(adapter), AMOUNT, MOCK_OUTPUT, 0
        );

        vm.prank(solver);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_emitsIntentRejected() public {
        // Verify IntentRejected is emitted for a representative rejection (step 0).
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        // The event uses the internal struct hash (before EIP-712 domain wrapping).
        bytes32 structHash = HashLib.hashCapability(cap);

        address rando = makeAddr("rando2");
        vm.expectEmit(true, true, false, false);
        emit CapabilityKernel.IntentRejected(
            structHash, bob, kernel.REASON_SOLVER_NOT_APPROVED(), 0, 0
        );
        vm.expectRevert(CapabilityKernel.SolverNotApproved.selector);
        vm.prank(rando);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    // =========================================================================
    // Solver fee
    // =========================================================================

    function test_solverFee_paidToSolver() public {
        Types.Capability memory cap = _defaultCap();
        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 50); // 0.5% fee

        uint256 expectedFee = (MOCK_OUTPUT * 50) / 10_000;
        uint256 beforeBal   = weth.balanceOf(solver);

        vm.prank(solver);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);

        assertEq(weth.balanceOf(solver), beforeBal + expectedFee);
    }

    function test_solverFee_reducesOutputPosition() public {
        Types.Capability memory cap = _defaultCap();
        uint16 feeBps = 50; // 0.5%
        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), feeBps);

        vm.prank(solver);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);

        uint256 fee        = (MOCK_OUTPUT * feeBps) / 10_000;
        uint256 netOut     = MOCK_OUTPUT - fee;
        bytes32 nullifier  = keccak256(abi.encode(intent.nonce, intent.positionCommitment));
        bytes32 outputSalt = keccak256(abi.encode(nullifier, "output"));
        bytes32 outHash    = keccak256(abi.encode(Types.Position({
            owner: alice, asset: address(weth), amount: netOut, salt: outputSalt
        })));
        assertTrue(vault.positionExists(outHash));
    }

    function test_solverFee_zero_noTransfer() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        uint256 before = weth.balanceOf(solver);
        vm.prank(solver);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
        assertEq(weth.balanceOf(solver), before); // no fee transfer
    }

    // =========================================================================
    // Verification step failures — one test per step
    // =========================================================================

    function test_revert_step0_solverNotApproved() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        address rando = makeAddr("rando");
        vm.expectRevert(CapabilityKernel.SolverNotApproved.selector);
        vm.prank(rando);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_setSolver_approveAndRevoke() public {
        address newSolver = makeAddr("newSolver");
        assertFalse(kernel.approvedSolvers(newSolver));

        vm.prank(owner);
        kernel.setSolver(newSolver, true);
        assertTrue(kernel.approvedSolvers(newSolver));

        vm.prank(owner);
        kernel.setSolver(newSolver, false);
        assertFalse(kernel.approvedSolvers(newSolver));
    }

    function test_revert_step1_invalidCapSig() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            ,
            bytes memory intentSig
        ) = _buildDefault();

        // Sign with wrong key (bob instead of alice).
        bytes32 capDigest = kernel.capabilityDigest(cap);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BOB_PK, capDigest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.expectRevert(CapabilityKernel.InvalidCapabilitySig.selector);
        kernel.executeIntent(pos, cap, intent, badSig, intentSig);
    }

    function test_revert_step2_invalidIntentSig() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
        ) = _buildDefault();

        // Sign with wrong key (alice instead of bob).
        bytes32 intentDigest_ = kernel.intentDigest(intent);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, intentDigest_);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.expectRevert(CapabilityKernel.InvalidIntentSig.selector);
        kernel.executeIntent(pos, cap, intent, capSig, badSig);
    }

    function test_revert_step3_capHashMismatch() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        // Mutate capability after signing — hash will differ.
        cap.expiry = block.timestamp + 2 days;

        vm.expectRevert(CapabilityKernel.InvalidCapabilitySig.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step4_wrongScope() public {
        Types.Capability memory cap = _defaultCap();
        cap.scope = keccak256("envelope.manage"); // wrong scope

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);

        vm.expectRevert(CapabilityKernel.WrongScope.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step5_capabilityExpired() public {
        Types.Capability memory cap = _defaultCap();
        cap.expiry = block.timestamp - 1; // expired

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);

        vm.expectRevert(CapabilityKernel.CapabilityExpired.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step6_capabilityRevoked() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        // Alice revokes capability nonce before execution.
        vm.prank(alice);
        kernel.revokeCapability(cap.nonce);

        vm.expectRevert(CapabilityKernel.CapabilityNonceRevoked.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step7_delegationDepthNotZero() public {
        Types.Capability memory cap = _defaultCap();
        cap.delegationDepth = 1; // Phase 1 rejects any sub-delegation

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);

        vm.expectRevert(CapabilityKernel.DelegationDepthNotSupported.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step8_intentExpired() public {
        Types.Capability memory cap = _defaultCap();

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);

        // Warp past the intent deadline.
        vm.warp(intent.deadline + 1);

        vm.expectRevert(CapabilityKernel.IntentExpired.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step9_unauthorizedSubmitter() public {
        Types.Capability memory cap = _defaultCap();
        address authorizedSolver = makeAddr("authorizedSolver");

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, authorizedSolver, 0); // locked to authorizedSolver

        // Different solver attempts to execute.
        vm.prank(solver);
        vm.expectRevert(CapabilityKernel.UnauthorizedSubmitter.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_step9_authorizedSubmitter_succeeds() public {
        Types.Capability memory cap = _defaultCap();

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, solver, 0); // locked to solver

        vm.prank(solver);
        bytes32 receipt = kernel.executeIntent(pos, cap, intent, capSig, intentSig);
        assertTrue(receipt != bytes32(0));
    }

    function test_revert_step10_solverFeeTooHigh() public {
        Types.Capability memory cap = _defaultCap();

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 101); // 1.01% > 1% max

        vm.expectRevert(CapabilityKernel.SolverFeeTooHigh.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step11_nullifierAlreadySpent() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        vm.prank(solver);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);

        // Second deposit with same salt produces same commitment + same nullifier.
        vm.prank(alice);
        vault.deposit(address(usdc), AMOUNT, SALT_1);

        vm.expectRevert(CapabilityKernel.NullifierSpent.selector);
        vm.prank(solver);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step12_commitmentMismatch() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        // Provide a wrong position preimage (wrong amount).
        Types.Position memory wrongPos = pos;
        wrongPos.amount = AMOUNT + 1;

        vm.expectRevert(CapabilityKernel.CommitmentMismatch.selector);
        kernel.executeIntent(wrongPos, cap, intent, capSig, intentSig);
    }

    function test_revert_step13_ownerMismatch() public {
        // Build a position owned by bob, but capability issued by alice.
        Types.Position memory bobPos = Types.Position({
            owner: bob,
            asset: address(usdc),
            amount: AMOUNT,
            salt:   SALT_1
        });
        bytes32 bobPosHash = keccak256(abi.encode(bobPos));

        // Bob deposits.
        usdc.mint(bob, AMOUNT);
        vm.startPrank(bob);
        usdc.approve(address(vault), AMOUNT);
        vault.deposit(address(usdc), AMOUNT, SALT_1);
        vm.stopPrank();

        Types.Capability memory cap = _defaultCap(); // issuer = alice
        bytes32 capHash = HashLib.hashCapability(cap);

        Types.Intent memory intent = Types.Intent({
            positionCommitment: bobPosHash,
            capabilityHash:     capHash,
            adapter:            address(adapter),
            adapterData:        bytes(""),
            minReturn:          MOCK_OUTPUT,
            deadline:           block.timestamp + 1 hours,
            nonce:              SALT_1,
            outputToken:        address(weth),
            returnTo:           address(0),      // address(0) = route to position.owner (default)
            submitter:          address(0),
            solverFeeBps:       0
        });

        bytes32 capDigest = kernel.capabilityDigest(cap);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(ALICE_PK, capDigest);
        bytes memory capSig = abi.encodePacked(cr, cs, cv);

        bytes32 intentDigest_ = kernel.intentDigest(intent);
        (uint8 iv, bytes32 ir, bytes32 is_) = vm.sign(BOB_PK, intentDigest_);
        bytes memory intentSig = abi.encodePacked(ir, is_, iv);

        vm.expectRevert(CapabilityKernel.OwnerMismatch.selector);
        kernel.executeIntent(bobPos, cap, intent, capSig, intentSig);
    }

    function test_revert_step14_positionNotFound() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        // Alice withdraws before execution — position no longer exists.
        vm.prank(alice);
        vault.withdraw(pos, alice);

        vm.expectRevert(CapabilityKernel.CommitmentMismatch.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step14_positionEncumbered() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        // Registry encumbers the position (simulates active envelope).
        address reg = makeAddr("reg");
        vm.prank(owner);
        vault.setEnvelopeRegistry(reg);
        vm.prank(reg);
        vault.encumber(intent.positionCommitment);

        vm.expectRevert(CapabilityKernel.PositionEncumberedError.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step15_adapterNotRegistered() public {
        address unregistered = makeAddr("unregistered");
        Types.Capability memory cap = _defaultCap();

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);

        // Swap to unregistered adapter after signing.
        intent.adapter = unregistered;

        // Re-sign with new adapter (old sig is invalid now).
        bytes32 intentDigest_ = kernel.intentDigest(intent);
        (uint8 iv, bytes32 ir, bytes32 is_) = vm.sign(BOB_PK, intentDigest_);
        intentSig = abi.encodePacked(ir, is_, iv);

        vm.expectRevert(CapabilityKernel.AdapterNotRegistered.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step15_adapterNotInAllowlist() public {
        // Capability restricts to a specific adapter (not the one we use).
        address otherAdapter = makeAddr("otherAdapter");
        vm.prank(owner);
        kernel.registerAdapter(otherAdapter);

        Types.Capability memory cap = _defaultCap();
        address[] memory allowed = new address[](1);
        allowed[0] = otherAdapter;
        cap.constraints.allowedAdapters = allowed;

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);

        vm.expectRevert(CapabilityKernel.AdapterNotAllowed.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step16_tokenInNotAllowed() public {
        Types.Capability memory cap = _defaultCap();
        address[] memory allowedIn = new address[](1);
        allowedIn[0] = address(weth); // only WETH allowed as input, but we use USDC
        cap.constraints.allowedTokensIn = allowedIn;

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);

        vm.expectRevert(CapabilityKernel.TokenInNotAllowed.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step16_tokenOutNotAllowed() public {
        Types.Capability memory cap = _defaultCap();
        address[] memory allowedOut = new address[](1);
        allowedOut[0] = address(usdc); // only USDC allowed as output, but intent uses WETH
        cap.constraints.allowedTokensOut = allowedOut;

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);

        vm.expectRevert(CapabilityKernel.TokenOutNotAllowed.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step17_adapterValidationFailed() public {
        adapter.setValidation(true, "mock failure");

        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        vm.expectRevert(
            abi.encodeWithSelector(CapabilityKernel.AdapterValidationFailed.selector, "mock failure")
        );
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_step18_periodLimitExceeded() public {
        Types.Capability memory cap = _defaultCap();
        cap.constraints.maxSpendPerPeriod = AMOUNT - 1; // limit below our spend amount
        cap.constraints.periodDuration    = 1 days;

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);

        vm.expectRevert(CapabilityKernel.PeriodLimitExceeded.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_insufficientOutput() public {
        // Adapter returns less than intent.minReturn.
        adapter.setMockAmountOut(MOCK_OUTPUT - 1);

        Types.Capability memory cap = _defaultCap();
        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);

        vm.expectRevert(CapabilityKernel.InsufficientOutput.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revert_minReturnBpsViolation() public {
        // Capability requires at least 98% return on input value.
        // AMOUNT = 1000e6 USDC, MOCK_OUTPUT = 0.5 WETH.
        // For the test to be meaningful we need the check to fire —
        // adapter.mockAmountOut < (AMOUNT * minReturnBps / 10000).
        // Set minReturnBps to 9800 and amountIn to 1000, minFloor = 980.
        // MOCK_OUTPUT (5e17) is a much smaller number in nominal terms, so this will fail.
        Types.Capability memory cap = _defaultCap();
        cap.constraints.minReturnBps = 9800; // 98% of amountIn in output units

        // Set output to 900 units (less than floor of 980).
        adapter.setMockAmountOut(900e6);

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);

        // Re-sign intent with new minReturn.
        intent.minReturn = 1; // low floor so InsufficientOutput doesn't fire first

        bytes32 intentDigest_ = kernel.intentDigest(intent);
        (uint8 iv, bytes32 ir, bytes32 is_) = vm.sign(BOB_PK, intentDigest_);
        intentSig = abi.encodePacked(ir, is_, iv);

        adapter.setMockAmountOut(900e6);
        weth.mint(address(adapter), 1_000e6);

        vm.expectRevert();
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    // =========================================================================
    // Period spending
    // =========================================================================

    function test_periodSpending_accumulates() public {
        // Set limit = 3000 USDC, period = 1 day. Spend 1000 twice — both succeed.
        Types.Capability memory cap = _defaultCap();
        cap.constraints.maxSpendPerPeriod = 3_000e6;
        cap.constraints.periodDuration    = 1 days;

        // First execution.
        (
            Types.Position memory pos1,
            Types.Intent memory intent1,
            bytes memory capSig1,
            bytes memory intentSig1
        ) = _buildBundle(cap, SALT_1, address(0), 0);
        vm.prank(solver);
        kernel.executeIntent(pos1, cap, intent1, capSig1, intentSig1);

        bytes32 capHash = HashLib.hashCapability(cap);
        uint256 periodIdx = block.timestamp / cap.constraints.periodDuration;
        assertEq(kernel.periodSpending(capHash, periodIdx), AMOUNT);

        // Second execution — different position, different nonce.
        vm.prank(alice);
        vault.deposit(address(usdc), AMOUNT, SALT_2);

        Types.Position memory pos2 = Types.Position({owner: alice, asset: address(usdc), amount: AMOUNT, salt: SALT_2});
        bytes32 pos2Hash = keccak256(abi.encode(pos2));
        Types.Intent memory intent2 = Types.Intent({
            positionCommitment: pos2Hash,
            capabilityHash:     capHash,
            adapter:            address(adapter),
            adapterData:        bytes(""),
            minReturn:          MOCK_OUTPUT,
            deadline:           block.timestamp + 1 hours,
            nonce:              SALT_2,
            outputToken:        address(weth),
            returnTo:           address(0),      // address(0) = route to position.owner (default)
            submitter:          address(0),
            solverFeeBps:       0
        });

        bytes32 capDigest2 = kernel.capabilityDigest(cap);
        (uint8 cv2, bytes32 cr2, bytes32 cs2) = vm.sign(ALICE_PK, capDigest2);
        bytes memory capSig2 = abi.encodePacked(cr2, cs2, cv2);

        bytes32 intentDigest2 = kernel.intentDigest(intent2);
        (uint8 iv2, bytes32 ir2, bytes32 is2) = vm.sign(BOB_PK, intentDigest2);
        bytes memory intentSig2 = abi.encodePacked(ir2, is2, iv2);

        vm.prank(solver);
        kernel.executeIntent(pos2, cap, intent2, capSig2, intentSig2);

        assertEq(kernel.periodSpending(capHash, periodIdx), 2 * AMOUNT);
    }

    function test_periodSpending_resets_newPeriod() public {
        Types.Capability memory cap = _defaultCap();
        cap.expiry                        = block.timestamp + 30 days; // survive the warp
        cap.constraints.maxSpendPerPeriod = AMOUNT; // exactly one spend per period
        cap.constraints.periodDuration    = 1 days;

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);

        vm.prank(solver);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);

        // Warp to next period.
        vm.warp(block.timestamp + 1 days);

        // Should succeed again because it's a new period with fresh counter.
        vm.prank(alice);
        vault.deposit(address(usdc), AMOUNT, SALT_2);

        Types.Position memory pos2 = Types.Position({owner: alice, asset: address(usdc), amount: AMOUNT, salt: SALT_2});
        bytes32 pos2Hash = keccak256(abi.encode(pos2));
        bytes32 capHash  = HashLib.hashCapability(cap);

        Types.Intent memory intent2 = Types.Intent({
            positionCommitment: pos2Hash,
            capabilityHash:     capHash,
            adapter:            address(adapter),
            adapterData:        bytes(""),
            minReturn:          MOCK_OUTPUT,
            deadline:           block.timestamp + 1 hours,
            nonce:              SALT_2,
            outputToken:        address(weth),
            returnTo:           address(0),      // address(0) = route to position.owner (default)
            submitter:          address(0),
            solverFeeBps:       0
        });

        bytes32 capDigest2 = kernel.capabilityDigest(cap);
        (uint8 cv2, bytes32 cr2, bytes32 cs2) = vm.sign(ALICE_PK, capDigest2);
        bytes memory capSig2 = abi.encodePacked(cr2, cs2, cv2);
        bytes32 intentDigest2 = kernel.intentDigest(intent2);
        (uint8 iv2, bytes32 ir2, bytes32 is2) = vm.sign(BOB_PK, intentDigest2);
        bytes memory intentSig2 = abi.encodePacked(ir2, is2, iv2);

        vm.prank(solver);
        bytes32 receipt = kernel.executeIntent(pos2, cap, intent2, capSig2, intentSig2);
        assertTrue(receipt != bytes32(0));
    }

    function test_periodSpending_unconstrained_noCheck() public {
        // maxSpendPerPeriod = 0 means no limit — large spend should succeed.
        Types.Capability memory cap = _defaultCap(); // already unconstrained
        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);
        vm.prank(solver);
        bytes32 receipt = kernel.executeIntent(pos, cap, intent, capSig, intentSig);
        assertTrue(receipt != bytes32(0));
    }

    // =========================================================================
    // Revocation
    // =========================================================================

    function test_revokeCapability_blocksExecution() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        vm.prank(alice);
        kernel.revokeCapability(cap.nonce);

        assertTrue(kernel.isRevoked(alice, cap.nonce));

        vm.expectRevert(CapabilityKernel.CapabilityNonceRevoked.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_revokeCapability_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit CapabilityKernel.CapabilityRevoked(alice, SALT_1);
        vm.prank(alice);
        kernel.revokeCapability(SALT_1);
    }

    function test_revokeCapability_doesNotAffectOtherNonces() public {
        vm.prank(alice);
        kernel.revokeCapability(SALT_1); // revoke nonce 1

        // Execute with a capability using nonce 2 — should succeed.
        Types.Capability memory cap = _defaultCap();
        cap.nonce = SALT_2; // different nonce

        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);

        vm.prank(solver);
        bytes32 receipt = kernel.executeIntent(pos, cap, intent, capSig, intentSig);
        assertTrue(receipt != bytes32(0));
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function test_registerAdapter_allows() public {
        address newAdapter = makeAddr("newAdapter");
        assertFalse(kernel.adapterRegistry(newAdapter));
        vm.prank(owner);
        kernel.registerAdapter(newAdapter);
        assertTrue(kernel.adapterRegistry(newAdapter));
    }

    function test_removeAdapter_blocks() public {
        vm.prank(owner);
        kernel.removeAdapter(address(adapter));
        assertFalse(kernel.adapterRegistry(address(adapter)));
    }

    function test_pause_preventsExecution() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        vm.prank(owner);
        kernel.pause();

        vm.expectRevert();
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function test_unpause_restoresExecution() public {
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        vm.prank(owner);
        kernel.pause();
        vm.prank(owner);
        kernel.unpause();

        vm.prank(solver);
        bytes32 receipt = kernel.executeIntent(pos, cap, intent, capSig, intentSig);
        assertTrue(receipt != bytes32(0));
    }

    // =========================================================================
    // Constraint allowlist interactions
    // =========================================================================

    function test_allowedAdapters_empty_allowsAll() public {
        // Empty allowedAdapters = any registered adapter is allowed.
        Types.Capability memory cap = _defaultCap();
        cap.constraints.allowedAdapters = new address[](0);
        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);
        vm.prank(solver);
        bytes32 receipt = kernel.executeIntent(pos, cap, intent, capSig, intentSig);
        assertTrue(receipt != bytes32(0));
    }

    function test_allowedAdapters_specific_allows() public {
        Types.Capability memory cap = _defaultCap();
        address[] memory allowed = new address[](1);
        allowed[0] = address(adapter);
        cap.constraints.allowedAdapters = allowed;
        (
            Types.Position memory pos,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildBundle(cap, SALT_1, address(0), 0);
        vm.prank(solver);
        bytes32 receipt = kernel.executeIntent(pos, cap, intent, capSig, intentSig);
        assertTrue(receipt != bytes32(0));
    }

    function test_tokenConstraints_empty_allowsAll() public {
        // Empty token lists = any token is allowed.
        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();
        vm.prank(solver);
        bytes32 receipt = kernel.executeIntent(pos, cap, intent, capSig, intentSig);
        assertTrue(receipt != bytes32(0));
    }

    // =========================================================================
    // View helpers
    // =========================================================================

    function test_capabilityDigest_deterministicForSameCap() public view {
        Types.Capability memory cap = _defaultCap();
        bytes32 d1 = kernel.capabilityDigest(cap);
        bytes32 d2 = kernel.capabilityDigest(cap);
        assertEq(d1, d2);
    }

    function test_intentDigest_changesWithNonce() public view {
        Types.Capability memory cap = _defaultCap();
        bytes32 capHash  = HashLib.hashCapability(cap);
        bytes32 posHash1 = keccak256("pos1");
        bytes32 posHash2 = keccak256("pos2");

        Types.Intent memory intent1 = Types.Intent({
            positionCommitment: posHash1,
            capabilityHash:     capHash,
            adapter:            address(adapter),
            adapterData:        bytes(""),
            minReturn:          MOCK_OUTPUT,
            deadline:           block.timestamp + 1 hours,
            nonce:              SALT_1,
            outputToken:        address(weth),
            returnTo:           address(0),      // address(0) = route to position.owner (default)
            submitter:          address(0),
            solverFeeBps:       0
        });

        Types.Intent memory intent2 = Types.Intent({
            positionCommitment: posHash2,   // different
            capabilityHash:     capHash,
            adapter:            address(adapter),
            adapterData:        bytes(""),
            minReturn:          MOCK_OUTPUT,
            deadline:           block.timestamp + 1 hours,
            nonce:              SALT_2,     // different
            outputToken:        address(weth),
            returnTo:           address(0),      // address(0) = route to position.owner (default)
            submitter:          address(0),
            solverFeeBps:       0
        });

        assertTrue(kernel.intentDigest(intent1) != kernel.intentDigest(intent2));
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    function testFuzz_signatureIsBinding(uint256 mutatedExpiry) public {
        // Mutating the capability after signing must invalidate the signature.
        vm.assume(mutatedExpiry != block.timestamp + 1 days);
        vm.assume(mutatedExpiry > block.timestamp + 1);

        (
            Types.Position memory pos,
            Types.Capability memory cap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildDefault();

        cap.expiry = mutatedExpiry; // mutate after signing

        vm.expectRevert(CapabilityKernel.InvalidCapabilitySig.selector);
        kernel.executeIntent(pos, cap, intent, capSig, intentSig);
    }

    function testFuzz_differentNonces_differentNullifiers(bytes32 n1, bytes32 n2) public pure {
        vm.assume(n1 != n2);
        bytes32 posHash   = keccak256("pos");
        bytes32 nullifier1 = keccak256(abi.encode(n1, posHash));
        bytes32 nullifier2 = keccak256(abi.encode(n2, posHash));
        assertTrue(nullifier1 != nullifier2);
    }

    function testFuzz_periodBoundary(uint256 ts, uint256 duration) public view {
        duration = bound(duration, 1, 365 days);
        ts       = bound(ts, 1, type(uint64).max);
        uint256 period1 = ts / duration;
        uint256 period2 = (ts + duration) / duration;
        assertTrue(period2 > period1);
    }
}
