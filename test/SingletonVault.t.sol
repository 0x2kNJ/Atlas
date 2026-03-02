// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {SingletonVault} from "../contracts/SingletonVault.sol";
import {Types} from "../contracts/Types.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Tests for SingletonVault.
///
/// Coverage targets:
///   deposit()          — happy path, fee-on-transfer handling, allowlist, edge cases, reentrancy
///   withdraw()         — happy path, owner check, encumbrance guard, not-found guard
///   emergencyWithdraw()— happy path, paused guard, owner check, encumbered bypass
///   release()          — kernel-only, preimage verification, encumbrance guard
///   depositFor()       — kernel-only, balance delta tracking
///   encumber()         — registry-only, existence check, idempotency
///   unencumber()       — registry-only
///   admin              — setKernel, setEnvelopeRegistry, allowlist management, pause/unpause
///   view functions     — positionExists, isEncumbered, computePositionHash
///   fuzz               — deposit amount/salt determinism, cross-owner collision resistance

contract SingletonVaultTest is Test {
    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    SingletonVault internal vault;
    MockERC20      internal usdc;
    MockERC20      internal weth;

    address internal owner    = makeAddr("owner");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal kernel   = makeAddr("kernel");
    address internal registry = makeAddr("registry");
    address internal attacker = makeAddr("attacker");

    bytes32 internal constant SALT_1 = bytes32(uint256(1));
    bytes32 internal constant SALT_2 = bytes32(uint256(2));

    uint256 internal constant AMOUNT = 1_000e6; // 1000 USDC

    function setUp() public {
        // Deploy vault with allowlist disabled so tests don't require allowlisting every token.
        vault = new SingletonVault(owner, false);
        usdc  = new MockERC20("USD Coin", "USDC", 6);
        weth  = new MockERC20("Wrapped Ether", "WETH", 18);

        // Wire up kernel and registry.
        vm.startPrank(owner);
        vault.setKernel(kernel);
        vault.setEnvelopeRegistry(registry);
        vm.stopPrank();

        // Fund alice and approve vault.
        usdc.mint(alice, 100_000e6);
        weth.mint(alice, 100e18);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        // Fund bob.
        usdc.mint(bob, 100_000e6);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _hash(address _owner, address _asset, uint256 _amount, bytes32 _salt)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(
            Types.Position({owner: _owner, asset: _asset, amount: _amount, salt: _salt})
        ));
    }

    function _position(address _owner, address _asset, uint256 _amount, bytes32 _salt)
        internal pure returns (Types.Position memory)
    {
        return Types.Position({owner: _owner, asset: _asset, amount: _amount, salt: _salt});
    }

    function _deposit(address who, uint256 amount, bytes32 salt) internal returns (bytes32) {
        vm.prank(who);
        return vault.deposit(address(usdc), amount, salt);
    }

    // =========================================================================
    // deposit()
    // =========================================================================

    function test_deposit_storesPosition() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        assertTrue(vault.positionExists(hash));
    }

    function test_deposit_returnsCorrectHash() public {
        bytes32 expected = _hash(alice, address(usdc), AMOUNT, SALT_1);
        bytes32 actual   = _deposit(alice, AMOUNT, SALT_1);
        assertEq(actual, expected);
    }

    function test_deposit_transfersTokensToVault() public {
        uint256 before = usdc.balanceOf(address(vault));
        _deposit(alice, AMOUNT, SALT_1);
        assertEq(usdc.balanceOf(address(vault)), before + AMOUNT);
    }

    function test_deposit_emitsPositionCreated() public {
        bytes32 expected = _hash(alice, address(usdc), AMOUNT, SALT_1);
        vm.expectEmit(true, true, true, true);
        emit SingletonVault.PositionCreated(expected, address(usdc), AMOUNT, alice);
        vm.prank(alice);
        vault.deposit(address(usdc), AMOUNT, SALT_1);
    }

    function test_deposit_differentSaltsProduceDifferentHashes() public {
        bytes32 h1 = _deposit(alice, AMOUNT, SALT_1);
        usdc.mint(alice, AMOUNT);
        bytes32 h2 = _deposit(alice, AMOUNT, SALT_2);
        assertTrue(h1 != h2);
        assertTrue(vault.positionExists(h1));
        assertTrue(vault.positionExists(h2));
    }

    function test_deposit_differentOwnersSameSaltDifferentHashes() public {
        bytes32 h1 = _deposit(alice, AMOUNT, SALT_1);
        bytes32 h2 = _deposit(bob, AMOUNT, SALT_1);
        assertTrue(h1 != h2);
    }

    function test_deposit_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(SingletonVault.ZeroAmount.selector);
        vault.deposit(address(usdc), 0, SALT_1);
    }

    function test_deposit_revert_saltCollision() public {
        _deposit(alice, AMOUNT, SALT_1);
        usdc.mint(alice, AMOUNT);
        bytes32 expected = _hash(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(alice);
        vm.expectRevert(SingletonVault.PositionAlreadyExists.selector);
        vault.deposit(address(usdc), AMOUNT, SALT_1);
        // Commitment from first deposit still intact.
        assertTrue(vault.positionExists(expected));
    }

    function test_deposit_revert_tokenNotAllowlisted() public {
        // Deploy vault with allowlist ENABLED.
        SingletonVault vaultWithList = new SingletonVault(owner, true);
        usdc.mint(alice, AMOUNT);
        vm.prank(alice);
        usdc.approve(address(vaultWithList), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(SingletonVault.TokenNotAllowlisted.selector);
        vaultWithList.deposit(address(usdc), AMOUNT, SALT_1);
    }

    function test_deposit_allowlist_onceApproved() public {
        SingletonVault vaultWithList = new SingletonVault(owner, true);
        vm.prank(owner);
        vaultWithList.setTokenAllowlist(address(usdc), true);
        usdc.mint(alice, AMOUNT);
        vm.prank(alice);
        usdc.approve(address(vaultWithList), type(uint256).max);
        vm.prank(alice);
        bytes32 hash = vaultWithList.deposit(address(usdc), AMOUNT, SALT_1);
        assertTrue(vaultWithList.positionExists(hash));
    }

    function test_deposit_feeOnTransferToken() public {
        // A token that takes a 1% fee on transfer.
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(alice, 10_000e18);
        vm.prank(alice);
        fot.approve(address(vault), type(uint256).max);

        uint256 depositAmount = 1_000e18;
        uint256 expectedReceived = depositAmount - (depositAmount / 100); // 1% fee

        vm.prank(alice);
        bytes32 hash = vault.deposit(address(fot), depositAmount, SALT_1);

        // Commitment must be for the amount ACTUALLY received, not the requested amount.
        bytes32 expected = _hash(alice, address(fot), expectedReceived, SALT_1);
        assertEq(hash, expected);
        assertTrue(vault.positionExists(expected));
        assertFalse(vault.positionExists(_hash(alice, address(fot), depositAmount, SALT_1)));
    }

    // =========================================================================
    // withdraw()
    // =========================================================================

    function test_withdraw_removesPosition() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(alice);
        vault.withdraw(pos, alice);
        assertFalse(vault.positionExists(hash));
    }

    function test_withdraw_transfersTokensToRecipient() public {
        _deposit(alice, AMOUNT, SALT_1);
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        uint256 before = usdc.balanceOf(bob);
        vm.prank(alice);
        vault.withdraw(pos, bob);
        assertEq(usdc.balanceOf(bob), before + AMOUNT);
    }

    function test_withdraw_revert_notOwner() public {
        _deposit(alice, AMOUNT, SALT_1);
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(bob);
        vm.expectRevert(SingletonVault.NotPositionOwner.selector);
        vault.withdraw(pos, bob);
    }

    function test_withdraw_revert_positionNotFound() public {
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(alice);
        vm.expectRevert(SingletonVault.PositionNotFound.selector);
        vault.withdraw(pos, alice);
    }

    function test_withdraw_revert_encumbered() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        vm.prank(registry);
        vault.encumber(hash);
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(alice);
        vm.expectRevert(SingletonVault.PositionIsEncumbered.selector);
        vault.withdraw(pos, alice);
    }

    function test_withdraw_revert_whenPaused() public {
        _deposit(alice, AMOUNT, SALT_1);
        vm.prank(owner);
        vault.pause();
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(pos, alice);
    }

    // =========================================================================
    // emergencyWithdraw()
    // =========================================================================

    function test_emergencyWithdraw_worksWhenPaused() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        vm.prank(owner);
        vault.pause();
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.emergencyWithdraw(pos, alice);
        assertFalse(vault.positionExists(hash));
        assertEq(usdc.balanceOf(alice), before + AMOUNT);
    }

    function test_emergencyWithdraw_bypassesEncumbrance() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        vm.prank(registry);
        vault.encumber(hash);
        assertTrue(vault.isEncumbered(hash));
        vm.prank(owner);
        vault.pause();
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(alice);
        vault.emergencyWithdraw(pos, alice);
        assertFalse(vault.positionExists(hash));
        assertFalse(vault.isEncumbered(hash));
    }

    function test_emergencyWithdraw_revert_notPaused() public {
        _deposit(alice, AMOUNT, SALT_1);
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(alice);
        vm.expectRevert();
        vault.emergencyWithdraw(pos, alice);
    }

    function test_emergencyWithdraw_revert_notOwner() public {
        _deposit(alice, AMOUNT, SALT_1);
        vm.prank(owner);
        vault.pause();
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(bob);
        vm.expectRevert(SingletonVault.NotPositionOwner.selector);
        vault.emergencyWithdraw(pos, bob);
    }

    // =========================================================================
    // release() — kernel-only
    // =========================================================================

    function test_release_transfersToExecutor() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        address executor = makeAddr("executor");
        uint256 before = usdc.balanceOf(executor);
        vm.prank(kernel);
        vault.release(hash, pos, executor);
        assertFalse(vault.positionExists(hash));
        assertEq(usdc.balanceOf(executor), before + AMOUNT);
    }

    function test_release_revert_notKernel() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(alice);
        vm.expectRevert(SingletonVault.OnlyKernel.selector);
        vault.release(hash, pos, alice);
    }

    function test_release_revert_commitmentMismatch() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        // Provide wrong amount in preimage.
        Types.Position memory wrong = _position(alice, address(usdc), AMOUNT + 1, SALT_1);
        vm.prank(kernel);
        vm.expectRevert(SingletonVault.CommitmentMismatch.selector);
        vault.release(hash, wrong, alice);
    }

    function test_release_revert_encumbered() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        vm.prank(registry);
        vault.encumber(hash);
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(kernel);
        vm.expectRevert(SingletonVault.PositionIsEncumbered.selector);
        vault.release(hash, pos, alice);
    }

    function test_release_revert_positionNotFound() public {
        // Kernel tries to release a position that was never deposited.
        bytes32 fakeHash = keccak256("fake");
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(kernel);
        vm.expectRevert(SingletonVault.PositionNotFound.selector);
        vault.release(fakeHash, pos, alice);
    }

    // =========================================================================
    // depositFor() — kernel-only
    // =========================================================================

    function test_depositFor_createsPositionForOwner() public {
        // Simulate kernel holding output tokens and creating a new position.
        usdc.mint(kernel, AMOUNT);
        vm.prank(kernel);
        usdc.approve(address(vault), AMOUNT);

        vm.prank(kernel);
        bytes32 hash = vault.depositFor(alice, address(usdc), AMOUNT, SALT_1);

        bytes32 expected = _hash(alice, address(usdc), AMOUNT, SALT_1);
        assertEq(hash, expected);
        assertTrue(vault.positionExists(hash));
    }

    function test_depositFor_revert_notKernel() public {
        usdc.mint(alice, AMOUNT);
        vm.prank(alice);
        usdc.approve(address(vault), AMOUNT);
        vm.prank(alice);
        vm.expectRevert(SingletonVault.OnlyKernel.selector);
        vault.depositFor(alice, address(usdc), AMOUNT, SALT_1);
    }

    function test_depositFor_feeOnTransferToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        uint256 gross = 1_000e18;
        uint256 net   = gross - (gross / 100);
        fot.mint(kernel, gross);
        vm.prank(kernel);
        fot.approve(address(vault), gross);
        vm.prank(kernel);
        bytes32 hash = vault.depositFor(alice, address(fot), gross, SALT_1);
        // Commitment uses actual received amount.
        assertEq(hash, _hash(alice, address(fot), net, SALT_1));
    }

    // =========================================================================
    // encumber() / unencumber()
    // =========================================================================

    function test_encumber_setsFlag() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        assertFalse(vault.isEncumbered(hash));
        vm.prank(registry);
        vault.encumber(hash);
        assertTrue(vault.isEncumbered(hash));
    }

    function test_encumber_emitsEvent() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        vm.expectEmit(true, false, false, false);
        emit SingletonVault.PositionEncumbered(hash);
        vm.prank(registry);
        vault.encumber(hash);
    }

    function test_encumber_revert_notRegistry() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        vm.prank(attacker);
        vm.expectRevert(SingletonVault.OnlyEnvelopeRegistry.selector);
        vault.encumber(hash);
    }

    function test_encumber_revert_positionNotFound() public {
        vm.prank(registry);
        vm.expectRevert(SingletonVault.PositionNotFound.selector);
        vault.encumber(keccak256("nonexistent"));
    }

    function test_encumber_revert_alreadyEncumbered() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        vm.startPrank(registry);
        vault.encumber(hash);
        vm.expectRevert(SingletonVault.AlreadyEncumbered.selector);
        vault.encumber(hash);
        vm.stopPrank();
    }

    function test_unencumber_clearsFlag() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        vm.startPrank(registry);
        vault.encumber(hash);
        vault.unencumber(hash);
        vm.stopPrank();
        assertFalse(vault.isEncumbered(hash));
    }

    function test_unencumber_revert_notRegistry() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        vm.prank(registry);
        vault.encumber(hash);
        vm.prank(attacker);
        vm.expectRevert(SingletonVault.OnlyEnvelopeRegistry.selector);
        vault.unencumber(hash);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function test_setKernel_updatesState() public {
        address newKernel = makeAddr("newKernel");
        // Deploy fresh vault so kernel is unset.
        SingletonVault v = new SingletonVault(owner, false);
        vm.prank(owner);
        v.setKernel(newKernel);
        assertEq(v.kernel(), newKernel);
    }

    function test_setKernel_revert_notOwner() public {
        SingletonVault v = new SingletonVault(owner, false);
        vm.prank(attacker);
        vm.expectRevert();
        v.setKernel(makeAddr("k"));
    }

    function test_setEnvelopeRegistry_updatesState() public {
        address newReg = makeAddr("newReg");
        vm.prank(owner);
        vault.setEnvelopeRegistry(newReg);
        assertEq(vault.envelopeRegistry(), newReg);
    }

    function test_pause_preventsDeposit() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(address(usdc), AMOUNT, SALT_1);
    }

    function test_unpause_restoresDeposit() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vault.unpause();
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        assertTrue(vault.positionExists(hash));
    }

    function test_setTokenAllowlist_allowsAndBlocks() public {
        SingletonVault v = new SingletonVault(owner, true);
        usdc.mint(alice, AMOUNT);
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);

        // Blocked before allowlisting.
        vm.prank(alice);
        vm.expectRevert(SingletonVault.TokenNotAllowlisted.selector);
        v.deposit(address(usdc), AMOUNT, SALT_1);

        // Allowed after.
        vm.prank(owner);
        v.setTokenAllowlist(address(usdc), true);
        vm.prank(alice);
        bytes32 hash = v.deposit(address(usdc), AMOUNT, SALT_1);
        assertTrue(v.positionExists(hash));

        // Blocked again after removal.
        vm.prank(owner);
        v.setTokenAllowlist(address(usdc), false);
        usdc.mint(alice, AMOUNT);
        vm.prank(alice);
        vm.expectRevert(SingletonVault.TokenNotAllowlisted.selector);
        v.deposit(address(usdc), AMOUNT, SALT_2);
    }

    // =========================================================================
    // View functions
    // =========================================================================

    function test_computePositionHash_matchesDeposit() public {
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        bytes32 fromView   = vault.computePositionHash(pos);
        bytes32 fromDeposit = _deposit(alice, AMOUNT, SALT_1);
        assertEq(fromView, fromDeposit);
    }

    function test_isEncumbered_returnsFalseByDefault() public {
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        assertFalse(vault.isEncumbered(hash));
    }

    // =========================================================================
    // Invariants / integration
    // =========================================================================

    function test_fullLifecycle_depositReleaseDepositFor() public {
        // 1. Alice deposits.
        bytes32 inHash = _deposit(alice, AMOUNT, SALT_1);
        assertTrue(vault.positionExists(inHash));

        // 2. Kernel releases to executor (simulates intent execution).
        address executor = makeAddr("executor");
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(kernel);
        vault.release(inHash, pos, executor);
        assertFalse(vault.positionExists(inHash));
        assertEq(usdc.balanceOf(executor), AMOUNT);

        // 3. Executor sends output tokens to vault (simulated here as weth).
        weth.mint(address(vault), 5e17); // 0.5 WETH returned
        vm.prank(executor);
        weth.transfer(address(vault), 0); // just to advance state

        // 4. Kernel commits output position.
        weth.mint(kernel, 5e17);
        vm.prank(kernel);
        weth.approve(address(vault), 5e17);
        vm.prank(kernel);
        bytes32 outHash = vault.depositFor(alice, address(weth), 5e17, SALT_2);

        assertTrue(vault.positionExists(outHash));
        assertEq(outHash, _hash(alice, address(weth), 5e17, SALT_2));
    }

    function test_fullLifecycle_envelopeEncumberTriggerUnencumber() public {
        // 1. Alice deposits.
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);

        // 2. Registry encumbers (envelope registered).
        vm.prank(registry);
        vault.encumber(hash);
        assertTrue(vault.isEncumbered(hash));

        // 3. Alice cannot withdraw while encumbered.
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(alice);
        vm.expectRevert(SingletonVault.PositionIsEncumbered.selector);
        vault.withdraw(pos, alice);

        // 4. Registry unencumbers (envelope triggered or cancelled).
        vm.prank(registry);
        vault.unencumber(hash);
        assertFalse(vault.isEncumbered(hash));

        // 5. Now kernel can release.
        vm.prank(kernel);
        vault.release(hash, pos, makeAddr("executor"));
        assertFalse(vault.positionExists(hash));
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    function testFuzz_deposit_hashDeterminism(uint256 amount, bytes32 salt) public {
        amount = bound(amount, 1, type(uint128).max);
        usdc.mint(alice, amount);
        bytes32 expected = _hash(alice, address(usdc), amount, salt);
        vm.prank(alice);
        bytes32 actual = vault.deposit(address(usdc), amount, salt);
        assertEq(actual, expected);
    }

    function testFuzz_differentOwnersDifferentHashes(
        uint256 amount,
        bytes32 salt,
        address otherOwner
    ) public view {
        vm.assume(otherOwner != alice);
        bytes32 aliceHash = _hash(alice, address(usdc), amount, salt);
        bytes32 otherHash = _hash(otherOwner, address(usdc), amount, salt);
        assertTrue(aliceHash != otherHash);
    }

    function testFuzz_release_onlyKernelCanRelease(address caller) public {
        vm.assume(caller != kernel);
        bytes32 hash = _deposit(alice, AMOUNT, SALT_1);
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(caller);
        vm.expectRevert(SingletonVault.OnlyKernel.selector);
        vault.release(hash, pos, caller);
    }

    function testFuzz_withdraw_onlyOwnerCanWithdraw(address caller) public {
        vm.assume(caller != alice);
        _deposit(alice, AMOUNT, SALT_1);
        Types.Position memory pos = _position(alice, address(usdc), AMOUNT, SALT_1);
        vm.prank(caller);
        vm.expectRevert(SingletonVault.NotPositionOwner.selector);
        vault.withdraw(pos, caller);
    }
}

// =============================================================================
// Fee-on-transfer mock — takes 1% on every transfer
// =============================================================================

contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("FOT Token", "FOT", 18) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount / 100;
        super.transfer(to, amount - fee);
        _burn(to, 0); // no-op to avoid unused warning
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount / 100;
        super.transferFrom(from, to, amount - fee);
        return true;
    }
}
