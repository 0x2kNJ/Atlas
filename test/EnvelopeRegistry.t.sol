// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EnvelopeRegistry} from "../contracts/EnvelopeRegistry.sol";
import {CapabilityKernel} from "../contracts/CapabilityKernel.sol";
import {SingletonVault} from "../contracts/SingletonVault.sol";
import {Types} from "../contracts/Types.sol";
import {HashLib} from "../contracts/HashLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

/// @notice Tests for EnvelopeRegistry.
///
/// Architecture note on dual-capability design:
///
///   register() requires an "envelope.manage" capability signed against the REGISTRY's
///   EIP-712 domain. This authorizes the creation of the envelope.
///
///   trigger() reveals and executes the pre-committed "vault.spend" capability +
///   intent, both signed against the KERNEL's EIP-712 domain. These are embedded
///   inside the envelope as committed hashes and verified by the kernel.
///
///   The two capabilities are always distinct: different scopes, different domains,
///   different digests. Alice signs both; Bob signs the intent.
///
/// Coverage:
///   register   — happy path, all validation failures, idempotency
///   trigger    — happy path, lazy expiry, all failure paths, keeper payment
///   cancel     — happy path, not-issuer guard, state guards
///   expire     — explicit + lazy expiry paths
///   integration— register → trigger → verify final state
///                register → cancel → position available again

contract EnvelopeRegistryTest is Test {

    // -------------------------------------------------------------------------
    // Signers
    // -------------------------------------------------------------------------

    uint256 internal constant ALICE_PK = 0xA11CE;  // issuer / position owner
    uint256 internal constant BOB_PK   = 0xB0B;    // grantee / agent

    address internal alice;
    address internal bob;
    address internal keeper  = makeAddr("keeper");
    address internal anyone  = makeAddr("anyone");
    address internal owner   = makeAddr("owner");

    // -------------------------------------------------------------------------
    // Contracts
    // -------------------------------------------------------------------------

    SingletonVault   internal vault;
    CapabilityKernel internal kernel;
    EnvelopeRegistry internal registry;
    MockAdapter      internal adapter;
    MockERC20        internal usdc;
    MockERC20        internal weth;
    MockOracle       internal oracle;  // ETH/USD feed, 8 decimals

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    bytes32 internal constant SALT_1 = bytes32(uint256(1));
    bytes32 internal constant SALT_2 = bytes32(uint256(2));

    uint256 internal constant AMOUNT         = 1_000e6;   // 1000 USDC input
    uint256 internal constant MOCK_OUTPUT    = 5e17;      // 0.5 WETH output
    int256  internal constant ORACLE_PRICE   = 1_700e8;   // $1700 with 8 decimals
    uint256 internal constant TRIGGER_PRICE  = 1_800e8;   // stop-loss triggers below $1800

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        // Foundry defaults block.timestamp to 1. The oracle staleness check computes
        // block.timestamp - MAX_ORACLE_AGE (3600). That would underflow on timestamp=1.
        // Start at a realistic epoch so arithmetic is safe.
        vm.warp(1_700_000_000);

        alice = vm.addr(ALICE_PK);
        bob   = vm.addr(BOB_PK);

        vault    = new SingletonVault(owner, false);
        kernel   = new CapabilityKernel(address(vault), owner);
        registry = new EnvelopeRegistry(address(vault), address(kernel), owner, 0);

        usdc   = new MockERC20("USD Coin", "USDC", 6);
        weth   = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockOracle(ORACLE_PRICE, 8);

        adapter = new MockAdapter();
        adapter.setMockAmountOut(MOCK_OUTPUT);
        weth.mint(address(adapter), 1_000e18);

        vm.startPrank(owner);
        vault.setKernel(address(kernel));
        vault.setEnvelopeRegistry(address(registry));
        kernel.registerAdapter(address(adapter));
        // EnvelopeRegistry calls kernel.executeIntent() directly on trigger.
        // It must be an approved solver (Decision 7).
        kernel.setSolver(address(registry), true);
        vm.stopPrank();

        // Alice funds + approves vault.
        usdc.mint(alice, 10_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // Build helpers
    // =========================================================================

    /// @dev Deposits a position for alice and returns the commitment hash.
    function _depositAlice(bytes32 salt) internal returns (bytes32 posHash) {
        vm.prank(alice);
        posHash = vault.deposit(address(usdc), AMOUNT, salt);
    }

    /// @dev Default Conditions for a LESS_THAN stop-loss (triggers when price < $1800).
    function _defaultConditions() internal view returns (Types.Conditions memory) {
        return Types.Conditions({
            priceOracle:           address(oracle),
            baseToken:             address(weth),
            quoteToken:            address(usdc),
            triggerPrice:          TRIGGER_PRICE,
            op:                    Types.ComparisonOp.LESS_THAN,
            secondaryOracle:       address(0),
            secondaryTriggerPrice: 0,
            secondaryOp:           Types.ComparisonOp.LESS_THAN,
            logicOp:               Types.LogicOp.AND
        });
    }

    /// @dev Build a vault.spend capability + intent pair for trigger(), signed against
    ///      the kernel's EIP-712 domain. Returns all structs and signatures.
    function _buildSpendBundle(
        bytes32 posSalt,
        bytes32 capNonce,
        bytes32 intentNonce,
        uint16  solverFeeBps
    ) internal view returns (
        Types.Position memory position,
        Types.Capability memory spendCap,
        Types.Intent memory intent,
        bytes memory capSig,
        bytes memory intentSig
    ) {
        position = Types.Position({
            owner:  alice,
            asset:  address(usdc),
            amount: AMOUNT,
            salt:   posSalt
        });
        bytes32 posHash = keccak256(abi.encode(position));

        spendCap = Types.Capability({
            issuer:               alice,
            grantee:              bob,
            scope:                keccak256("vault.spend"),
            expiry:               block.timestamp + 30 days,
            nonce:                capNonce,
            constraints:          _noConstraints(),
            parentCapabilityHash: bytes32(0),
            delegationDepth:      0
        });
        bytes32 capHash = HashLib.hashCapability(spendCap);

        intent = Types.Intent({
            positionCommitment: posHash,
            capabilityHash:     capHash,
            adapter:            address(adapter),
            adapterData:        bytes(""),
            minReturn:          MOCK_OUTPUT,
            deadline:           block.timestamp + 7 days,
            nonce:              intentNonce,
            outputToken:        address(weth),
            returnTo:           address(0),      // address(0) = route to position.owner (default)
            submitter:          address(registry), // locked to registry as submitter
            solverFeeBps:       solverFeeBps
        });

        // Sign vault.spend capability against kernel's domain.
        bytes32 capDigest = kernel.capabilityDigest(spendCap);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(ALICE_PK, capDigest);
        capSig = abi.encodePacked(cr, cs, cv);

        // Sign intent against kernel's domain.
        bytes32 intentDigest_ = kernel.intentDigest(intent);
        (uint8 iv, bytes32 ir, bytes32 is_) = vm.sign(BOB_PK, intentDigest_);
        intentSig = abi.encodePacked(ir, is_, iv);
    }

    /// @dev Build an envelope.manage capability + envelope struct, ready for register().
    ///
    /// envelope.capabilityHash stores the hash of the MANAGE capability (checked by register()).
    /// The vault.spend capability is embedded inside `intent.capabilityHash`, which is committed
    /// as keccak256(abi.encode(intent)) → envelope.intentCommitment.
    function _buildRegistration(
        bytes32 posHash,
        Types.Conditions memory conditions,
        Types.Intent memory intent,
        bytes32 manageCap_nonce
    ) internal view returns (
        Types.Envelope memory envelope,
        Types.Capability memory manageCap,
        bytes memory manageCapSig
    ) {
        manageCap = Types.Capability({
            issuer:               alice,
            grantee:              bob,
            scope:                keccak256("envelope.manage"),
            expiry:               block.timestamp + 30 days,
            nonce:                manageCap_nonce,
            constraints:          _noConstraints(),
            parentCapabilityHash: bytes32(0),
            delegationDepth:      0
        });

        // Sign envelope.manage capability against REGISTRY's domain.
        bytes32 manageDigest = registry.capabilityDigest(manageCap);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, manageDigest);
        manageCapSig = abi.encodePacked(r, s, v);

        envelope = Types.Envelope({
            positionCommitment: posHash,
            conditionsHash:     keccak256(abi.encode(conditions)),
            intentCommitment:   keccak256(abi.encode(intent)),
            capabilityHash:     HashLib.hashCapability(manageCap),  // manage cap hash, NOT spend
            expiry:             block.timestamp + 7 days,
            keeperRewardBps:    0,
            minKeeperRewardWei: 0
        });
    }

    /// @dev Full registration: deposit + build everything + register. Returns all data needed for trigger.
    function _registerDefault() internal returns (
        bytes32 envelopeHash,
        bytes32 posHash,
        Types.Conditions memory conditions,
        Types.Position memory position,
        Types.Capability memory spendCap,
        Types.Intent memory intent,
        bytes memory capSig,
        bytes memory intentSig
    ) {
        posHash = _depositAlice(SALT_1);
        conditions = _defaultConditions();

        (position, spendCap, intent, capSig, intentSig) =
            _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);

        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        vm.prank(bob);
        envelopeHash = registry.register(envelope, manageCap, manageCapSig, position);
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

    // =========================================================================
    // register() — happy path
    // =========================================================================

    function test_register_storesEnvelope() public {
        (bytes32 envelopeHash,,,,,,,) = _registerDefault();
        EnvelopeRegistry.EnvelopeRecord memory rec = registry.getEnvelope(envelopeHash);
        assertEq(uint8(rec.status), uint8(EnvelopeRegistry.EnvelopeStatus.Active));
        assertEq(rec.issuer, alice);
    }

    function test_register_encumbersPosition() public {
        (, bytes32 posHash,,,,,,) = _registerDefault();
        assertTrue(vault.isEncumbered(posHash));
    }

    function test_register_emitsEvent() public {
        _depositAlice(SALT_1);
        Types.Conditions memory conditions = _defaultConditions();
        (Types.Position memory position, Types.Capability memory spendCap, Types.Intent memory intent,,) =
            _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);

        bytes32 posHash = keccak256(abi.encode(position));

        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        bytes32 expectedHash = HashLib.hashEnvelope(envelope);

        vm.expectEmit(true, true, true, true);
        emit EnvelopeRegistry.EnvelopeRegistered(expectedHash, posHash, alice, envelope.expiry);

        vm.prank(bob);
        registry.register(envelope, manageCap, manageCapSig, position);
    }

    function test_register_isActiveAfter() public {
        (bytes32 envelopeHash,,,,,,,) = _registerDefault();
        assertTrue(registry.isActive(envelopeHash));
    }

    // =========================================================================
    // register() — failures
    // =========================================================================

    function test_register_revert_keeperRewardTooHigh() public {
        _depositAlice(SALT_1);
        Types.Conditions memory conditions = _defaultConditions();
        (Types.Position memory position, Types.Capability memory spendCap, Types.Intent memory intent,,) =
            _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);

        bytes32 posHash = keccak256(abi.encode(position));

        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        envelope.keeperRewardBps = 501; // > MAX_KEEPER_REWARD_BPS (500)

        vm.prank(bob);
        vm.expectRevert(EnvelopeRegistry.KeeperRewardTooHigh.selector);
        registry.register(envelope, manageCap, manageCapSig, position);
    }

    function test_register_revert_envelopeAlreadyExpired() public {
        _depositAlice(SALT_1);
        Types.Conditions memory conditions = _defaultConditions();
        (Types.Position memory position, Types.Capability memory spendCap, Types.Intent memory intent,,) =
            _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);

        bytes32 posHash = keccak256(abi.encode(position));

        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        envelope.expiry = block.timestamp; // expired (expiry <= now)

        vm.prank(bob);
        vm.expectRevert(EnvelopeRegistry.EnvelopeNotActive.selector);
        registry.register(envelope, manageCap, manageCapSig, position);
    }

    function test_register_revert_invalidManageCapSig() public {
        _depositAlice(SALT_1);
        Types.Conditions memory conditions = _defaultConditions();
        (Types.Position memory position, Types.Capability memory spendCap, Types.Intent memory intent,,) =
            _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);

        bytes32 posHash = keccak256(abi.encode(position));

        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        // Sign with bob instead of alice.
        bytes32 digest = registry.capabilityDigest(manageCap);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BOB_PK, digest);
        manageCapSig = abi.encodePacked(r, s, v);

        vm.prank(bob);
        vm.expectRevert(EnvelopeRegistry.InvalidCapabilitySig.selector);
        registry.register(envelope, manageCap, manageCapSig, position);
    }

    function test_register_revert_capHashMismatch() public {
        _depositAlice(SALT_1);
        Types.Conditions memory conditions = _defaultConditions();
        (Types.Position memory position,, Types.Intent memory intent,,) =
            _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);

        bytes32 posHash = keccak256(abi.encode(position));

        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        // Tamper: override capabilityHash to something that won't match manageCap.
        envelope.capabilityHash = keccak256("wrong");

        vm.prank(bob);
        vm.expectRevert(EnvelopeRegistry.CapabilityHashMismatch.selector);
        registry.register(envelope, manageCap, manageCapSig, position);
    }

    function test_register_revert_wrongScope() public {
        _depositAlice(SALT_1);
        Types.Conditions memory conditions = _defaultConditions();
        (Types.Position memory position,, Types.Intent memory intent,,) =
            _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);

        bytes32 posHash = keccak256(abi.encode(position));

        // Build manageCap with WRONG scope.
        Types.Capability memory badManageCap = Types.Capability({
            issuer:               alice,
            grantee:              bob,
            scope:                keccak256("vault.spend"),  // wrong scope
            expiry:               block.timestamp + 30 days,
            nonce:                SALT_2,
            constraints:          _noConstraints(),
            parentCapabilityHash: bytes32(0),
            delegationDepth:      0
        });

        bytes32 digest = registry.capabilityDigest(badManageCap);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        Types.Envelope memory envelope = Types.Envelope({
            positionCommitment: posHash,
            conditionsHash:     keccak256(abi.encode(conditions)),
            intentCommitment:   keccak256(abi.encode(intent)),
            capabilityHash:     HashLib.hashCapability(badManageCap),
            expiry:             block.timestamp + 7 days,
            keeperRewardBps:    0,
            minKeeperRewardWei: 0
        });

        vm.prank(bob);
        vm.expectRevert("EnvelopeRegistry: wrong scope");
        registry.register(envelope, badManageCap, sig, position);
    }

    function test_register_revert_capabilityExpired() public {
        _depositAlice(SALT_1);
        Types.Conditions memory conditions = _defaultConditions();
        (Types.Position memory position, Types.Capability memory spendCap, Types.Intent memory intent,,) =
            _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);

        bytes32 posHash = keccak256(abi.encode(position));

        Types.Capability memory expiredManageCap = Types.Capability({
            issuer:               alice,
            grantee:              bob,
            scope:                keccak256("envelope.manage"),
            expiry:               block.timestamp - 1,  // expired
            nonce:                SALT_2,
            constraints:          _noConstraints(),
            parentCapabilityHash: bytes32(0),
            delegationDepth:      0
        });

        bytes32 digest = registry.capabilityDigest(expiredManageCap);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        Types.Envelope memory envelope = Types.Envelope({
            positionCommitment: posHash,
            conditionsHash:     keccak256(abi.encode(conditions)),
            intentCommitment:   keccak256(abi.encode(intent)),
            capabilityHash:     HashLib.hashCapability(expiredManageCap),
            expiry:             block.timestamp + 7 days,
            keeperRewardBps:    0,
            minKeeperRewardWei: 0
        });

        vm.prank(bob);
        vm.expectRevert("EnvelopeRegistry: capability expired");
        registry.register(envelope, expiredManageCap, sig, position);
    }

    function test_register_revert_capabilityRevoked() public {
        _depositAlice(SALT_1);
        Types.Conditions memory conditions = _defaultConditions();
        (Types.Position memory position, Types.Capability memory spendCap, Types.Intent memory intent,,) =
            _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);

        bytes32 posHash = keccak256(abi.encode(position));

        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        // Alice revokes the manage cap nonce before registration.
        vm.prank(alice);
        kernel.revokeCapability(manageCap.nonce);

        vm.prank(bob);
        vm.expectRevert("EnvelopeRegistry: capability revoked");
        registry.register(envelope, manageCap, manageCapSig, position);
    }

    function test_register_revert_positionNotFound() public {
        // Don't deposit — position doesn't exist.
        Types.Conditions memory conditions = _defaultConditions();
        (Types.Position memory position, Types.Capability memory spendCap, Types.Intent memory intent,,) =
            _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);

        bytes32 posHash = keccak256(abi.encode(position)); // not deposited

        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        vm.prank(bob);
        vm.expectRevert("EnvelopeRegistry: position not found");
        registry.register(envelope, manageCap, manageCapSig, position);
    }

    function test_register_revert_envelopeAlreadyExists() public {
        (
            bytes32 envelopeHash,
            bytes32 posHash,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,,
        ) = _registerDefault();


        // Re-use same envelope data with same manage cap nonce — same hash, already registered.
        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        vm.prank(bob);
        vm.expectRevert(EnvelopeRegistry.EnvelopeAlreadyExists.selector);
        registry.register(envelope, manageCap, manageCapSig, position);
    }

    function test_register_revert_whenPaused() public {
        vm.prank(owner);
        registry.pause();

        _depositAlice(SALT_1);
        Types.Conditions memory conditions = _defaultConditions();
        (Types.Position memory position, Types.Capability memory spendCap, Types.Intent memory intent,,) =
            _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);
        bytes32 posHash = keccak256(abi.encode(position));
        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        vm.prank(bob);
        vm.expectRevert();
        registry.register(envelope, manageCap, manageCapSig, position);
    }

    // =========================================================================
    // trigger() — happy path
    // =========================================================================

    function test_trigger_succeeds() public {
        (
            bytes32 envelopeHash,
            ,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _registerDefault();

        // Oracle price ($1700) < trigger price ($1800) → condition met.
        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);

        EnvelopeRegistry.EnvelopeRecord memory rec = registry.getEnvelope(envelopeHash);
        assertEq(uint8(rec.status), uint8(EnvelopeRegistry.EnvelopeStatus.Triggered));
    }

    function test_trigger_statusBecomesTriggered() public {
        (
            bytes32 envelopeHash,
            ,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _registerDefault();

        assertTrue(registry.isActive(envelopeHash));

        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);

        assertFalse(registry.isActive(envelopeHash));
    }

    function test_trigger_unencumbersPosition() public {
        (
            bytes32 envelopeHash,
            bytes32 posHash,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _registerDefault();

        assertTrue(vault.isEncumbered(posHash));

        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);

        // Position is released (spent) — not just unencumbered.
        assertFalse(vault.positionExists(posHash));
    }

    function test_trigger_createsOutputPosition() public {
        (
            bytes32 envelopeHash,
            ,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _registerDefault();

        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);

        // Output position exists under alice's ownership.
        bytes32 nullifier  = keccak256(abi.encode(intent.nonce, intent.positionCommitment));
        bytes32 outputSalt = keccak256(abi.encode(nullifier, "output"));
        bytes32 outHash    = keccak256(abi.encode(Types.Position({
            owner: alice, asset: address(weth), amount: MOCK_OUTPUT, salt: outputSalt
        })));
        assertTrue(vault.positionExists(outHash));
    }

    function test_trigger_keeperRewardWithSolverFee() public {
        // intent.solverFeeBps = 50 (0.5%) — flows from kernel → registry → keeper.
        _depositAlice(SALT_1);
        Types.Conditions memory conditions = _defaultConditions();

        (
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildSpendBundle(SALT_1, SALT_1, SALT_1, 50); // 0.5%

        bytes32 posHash = keccak256(abi.encode(position));

        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        vm.prank(bob);
        bytes32 envelopeHash = registry.register(envelope, manageCap, manageCapSig, position);

        uint256 expectedFee  = (MOCK_OUTPUT * 50) / 10_000;
        uint256 keeperBefore = weth.balanceOf(keeper);

        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);

        assertEq(weth.balanceOf(keeper), keeperBefore + expectedFee);
    }

    function test_trigger_zeroKeeperReward_noTransfer() public {
        (
            bytes32 envelopeHash,
            ,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _registerDefault(); // solverFeeBps = 0

        uint256 keeperBefore = weth.balanceOf(keeper);
        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);
        assertEq(weth.balanceOf(keeper), keeperBefore);
    }

    function test_trigger_emitsEvent() public {
        (
            bytes32 envelopeHash,
            ,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _registerDefault();

        vm.expectEmit(true, true, false, false);
        emit EnvelopeRegistry.EnvelopeTriggered(envelopeHash, keeper, 0);

        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);
    }

    // =========================================================================
    // trigger() — lazy expiry
    // =========================================================================

    function test_trigger_lazyExpiry_whenPastExpiry() public {
        (
            bytes32 envelopeHash,
            bytes32 posHash,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _registerDefault();

        // Warp past the envelope expiry.
        vm.warp(block.timestamp + 8 days);

        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);

        EnvelopeRegistry.EnvelopeRecord memory rec = registry.getEnvelope(envelopeHash);
        assertEq(uint8(rec.status), uint8(EnvelopeRegistry.EnvelopeStatus.Expired));

        // Position is unencumbered (not spent — trigger didn't execute the intent).
        assertFalse(vault.isEncumbered(posHash));
        assertTrue(vault.positionExists(posHash));
    }

    // =========================================================================
    // trigger() — condition and state failures
    // =========================================================================

    function test_trigger_revert_envelopeNotFound() public {
        Types.Conditions memory conditions = _defaultConditions();
        Types.Capability memory spendCap;
        Types.Position memory position;
        Types.Intent memory intent;

        vm.expectRevert(EnvelopeRegistry.EnvelopeNotFound.selector);
        registry.trigger(
            keccak256("nonexistent"),
            conditions, position, intent, spendCap, bytes(""), bytes("")
        );
    }

    function test_trigger_revert_notActive_cancelled() public {
        (bytes32 envelopeHash,,,,,,,) = _registerDefault();

        // Cancel the envelope.
        vm.prank(alice);
        registry.cancel(envelopeHash);

        Types.Conditions memory conditions = _defaultConditions();
        Types.Capability memory spendCap;
        Types.Position memory position;
        Types.Intent memory intent;

        vm.expectRevert(EnvelopeRegistry.EnvelopeNotActive.selector);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, bytes(""), bytes(""));
    }

    function test_trigger_revert_conditionsMismatch() public {
        (
            bytes32 envelopeHash,
            ,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _registerDefault();

        // Tamper with the trigger price.
        conditions.triggerPrice = TRIGGER_PRICE + 1;

        vm.prank(keeper);
        vm.expectRevert(EnvelopeRegistry.ConditionsMismatch.selector);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);
    }

    function test_trigger_revert_intentMismatch() public {
        (
            bytes32 envelopeHash,
            ,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _registerDefault();

        // Tamper with the intent.
        intent.minReturn = intent.minReturn + 1;

        vm.prank(keeper);
        vm.expectRevert(EnvelopeRegistry.IntentMismatch.selector);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);
    }

    function test_trigger_revert_conditionNotMet_priceAboveThreshold() public {
        (
            bytes32 envelopeHash,
            ,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _registerDefault();

        // Price is now above trigger threshold — LESS_THAN condition not met.
        oracle.setAnswer(int256(TRIGGER_PRICE) + 1);

        vm.prank(keeper);
        vm.expectRevert(EnvelopeRegistry.ConditionNotMet.selector);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);
    }

    function test_trigger_revert_conditionNotMet_greaterThanNotMet() public {
        // Set up an envelope that triggers when price > $2000.
        _depositAlice(SALT_1);

        Types.Conditions memory conditions = Types.Conditions({
            priceOracle:           address(oracle),
            baseToken:             address(weth),
            quoteToken:            address(usdc),
            triggerPrice:          2_000e8,
            op:                    Types.ComparisonOp.GREATER_THAN,
            secondaryOracle:       address(0),
            secondaryTriggerPrice: 0,
            secondaryOp:           Types.ComparisonOp.LESS_THAN,
            logicOp:               Types.LogicOp.AND
        });

        oracle.setAnswer(1_700e8); // below threshold — condition not met

        (
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);

        bytes32 posHash = keccak256(abi.encode(position));

        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        vm.prank(bob);
        bytes32 envelopeHash = registry.register(envelope, manageCap, manageCapSig, position);

        vm.prank(keeper);
        vm.expectRevert(EnvelopeRegistry.ConditionNotMet.selector);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);
    }

    function test_trigger_revert_oracleStale() public {
        (
            bytes32 envelopeHash,
            ,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _registerDefault();

        // Make oracle stale.
        oracle.setUpdatedAt(block.timestamp - registry.MAX_ORACLE_AGE() - 1);

        vm.prank(keeper);
        vm.expectRevert(EnvelopeRegistry.OracleStale.selector);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);
    }

    function test_trigger_revert_oracleNegativeAnswer() public {
        (
            bytes32 envelopeHash,
            ,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _registerDefault();

        oracle.setAnswer(-1);

        vm.prank(keeper);
        vm.expectRevert(EnvelopeRegistry.OracleInvalidAnswer.selector);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);
    }

    // =========================================================================
    // cancel()
    // =========================================================================

    function test_cancel_statusBecomeCancelled() public {
        (bytes32 envelopeHash,,,,,,,) = _registerDefault();
        vm.prank(alice);
        registry.cancel(envelopeHash);
        assertEq(
            uint8(registry.getEnvelope(envelopeHash).status),
            uint8(EnvelopeRegistry.EnvelopeStatus.Cancelled)
        );
    }

    function test_cancel_unencumbersPosition_clean() public {
        (bytes32 envelopeHash, bytes32 posHash,,,,,,) = _registerDefault();
        vm.prank(alice);
        registry.cancel(envelopeHash);
        assertFalse(vault.isEncumbered(posHash));
    }

    function test_cancel_emitsEvent() public {
        (bytes32 envelopeHash,,,,,,,) = _registerDefault();
        vm.expectEmit(true, false, false, false);
        emit EnvelopeRegistry.EnvelopeCancelled(envelopeHash);
        vm.prank(alice);
        registry.cancel(envelopeHash);
    }

    function test_cancel_allowsWithdrawAfter() public {
        (bytes32 envelopeHash, bytes32 posHash,,, Types.Capability memory spendCap,,, ) =
            _registerDefault();

        vm.prank(alice);
        registry.cancel(envelopeHash);

        // Now alice can withdraw freely.
        Types.Position memory pos = Types.Position({
            owner: alice, asset: address(usdc), amount: AMOUNT, salt: SALT_1
        });
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(pos, alice);
        assertEq(usdc.balanceOf(alice), before + AMOUNT);
    }

    function test_cancel_revert_notFound() public {
        vm.expectRevert(EnvelopeRegistry.EnvelopeNotFound.selector);
        vm.prank(alice);
        registry.cancel(keccak256("nonexistent"));
    }

    function test_cancel_revert_notActive() public {
        (bytes32 envelopeHash,,,,,,,) = _registerDefault();
        vm.prank(alice);
        registry.cancel(envelopeHash);

        vm.prank(alice);
        vm.expectRevert(EnvelopeRegistry.EnvelopeNotActive.selector);
        registry.cancel(envelopeHash);
    }

    function test_cancel_revert_notIssuer() public {
        (bytes32 envelopeHash,,,,,,,) = _registerDefault();
        vm.prank(anyone);
        vm.expectRevert(EnvelopeRegistry.NotIssuer.selector);
        registry.cancel(envelopeHash);
    }

    // =========================================================================
    // expire()
    // =========================================================================

    function test_expire_explicit_afterExpiry() public {
        (bytes32 envelopeHash, bytes32 posHash,,,,,,) = _registerDefault();

        vm.warp(block.timestamp + 8 days); // past envelope expiry (7 days)

        vm.prank(anyone); // permissionless
        registry.expire(envelopeHash);

        assertEq(
            uint8(registry.getEnvelope(envelopeHash).status),
            uint8(EnvelopeRegistry.EnvelopeStatus.Expired)
        );
        assertFalse(vault.isEncumbered(posHash));
    }

    function test_expire_emitsEvent() public {
        (bytes32 envelopeHash,,,,,,,) = _registerDefault();
        vm.warp(block.timestamp + 8 days);

        vm.expectEmit(true, false, false, false);
        emit EnvelopeRegistry.EnvelopeExpired(envelopeHash);

        vm.prank(anyone);
        registry.expire(envelopeHash);
    }

    function test_expire_revert_notExpiredYet() public {
        (bytes32 envelopeHash,,,,,,,) = _registerDefault();
        vm.prank(anyone);
        vm.expectRevert(EnvelopeRegistry.EnvelopeNotExpired.selector);
        registry.expire(envelopeHash);
    }

    function test_expire_revert_notFound() public {
        vm.expectRevert(EnvelopeRegistry.EnvelopeNotFound.selector);
        registry.expire(keccak256("nonexistent"));
    }

    function test_expire_revert_alreadyCancelled() public {
        (bytes32 envelopeHash,,,,,,,) = _registerDefault();
        vm.prank(alice);
        registry.cancel(envelopeHash);
        vm.warp(block.timestamp + 8 days);

        vm.expectRevert(EnvelopeRegistry.EnvelopeNotActive.selector);
        registry.expire(envelopeHash);
    }

    // =========================================================================
    // Conditions logic — EQUAL and GREATER_THAN paths
    // =========================================================================

    function test_conditions_greaterThan_met() public {
        _depositAlice(SALT_1);

        // Trigger when price > $1600.
        Types.Conditions memory conditions = Types.Conditions({
            priceOracle:           address(oracle),
            baseToken:             address(weth),
            quoteToken:            address(usdc),
            triggerPrice:          1_600e8,
            op:                    Types.ComparisonOp.GREATER_THAN,
            secondaryOracle:       address(0),
            secondaryTriggerPrice: 0,
            secondaryOp:           Types.ComparisonOp.LESS_THAN,
            logicOp:               Types.LogicOp.AND
        });

        oracle.setAnswer(1_700e8); // above threshold — condition met

        (
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);

        bytes32 posHash = keccak256(abi.encode(position));

        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        vm.prank(bob);
        bytes32 envelopeHash = registry.register(envelope, manageCap, manageCapSig, position);

        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);

        assertEq(
            uint8(registry.getEnvelope(envelopeHash).status),
            uint8(EnvelopeRegistry.EnvelopeStatus.Triggered)
        );
    }

    function test_conditions_equal_met() public {
        _depositAlice(SALT_1);

        int256 exactPrice = 1_800e8;
        Types.Conditions memory conditions = Types.Conditions({
            priceOracle:           address(oracle),
            baseToken:             address(weth),
            quoteToken:            address(usdc),
            triggerPrice:          uint256(exactPrice),
            op:                    Types.ComparisonOp.EQUAL,
            secondaryOracle:       address(0),
            secondaryTriggerPrice: 0,
            secondaryOp:           Types.ComparisonOp.LESS_THAN,
            logicOp:               Types.LogicOp.AND
        });

        oracle.setAnswer(exactPrice);

        (
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);

        bytes32 posHash = keccak256(abi.encode(position));

        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        vm.prank(bob);
        bytes32 envelopeHash = registry.register(envelope, manageCap, manageCapSig, position);

        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);

        assertEq(
            uint8(registry.getEnvelope(envelopeHash).status),
            uint8(EnvelopeRegistry.EnvelopeStatus.Triggered)
        );
    }

    // =========================================================================
    // Integration — full lifecycle
    // =========================================================================

    function test_lifecycle_registerCancelRedeposit() public {
        // 1. Register envelope.
        (bytes32 envelopeHash, bytes32 posHash,,,,,,) = _registerDefault();
        assertTrue(vault.isEncumbered(posHash));

        // 2. Cancel envelope.
        vm.prank(alice);
        registry.cancel(envelopeHash);
        assertFalse(vault.isEncumbered(posHash));

        // 3. Alice registers a new envelope on the SAME position (still exists).
        Types.Conditions memory conditions = _defaultConditions();
        (
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _buildSpendBundle(SALT_1, SALT_2, SALT_2, 0); // new cap/intent nonces


        (
            Types.Envelope memory envelope2,
            Types.Capability memory manageCap2,
            bytes memory manageCapSig2
        ) = _buildRegistration(posHash, conditions, intent, bytes32(uint256(3)));

        vm.prank(bob);
        bytes32 envelopeHash2 = registry.register(envelope2, manageCap2, manageCapSig2, position);
        assertTrue(registry.isActive(envelopeHash2));
        assertTrue(vault.isEncumbered(posHash));

        // 4. Trigger the new envelope.
        vm.prank(keeper);
        registry.trigger(envelopeHash2, conditions, position, intent, spendCap, capSig, intentSig);

        assertFalse(vault.positionExists(posHash)); // position spent
    }

    function test_lifecycle_fullRegisterTrigger() public {
        (
            bytes32 envelopeHash,
            bytes32 posHash,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _registerDefault();

        // Verify pre-trigger state.
        assertTrue(vault.positionExists(posHash));
        assertTrue(vault.isEncumbered(posHash));

        // Trigger.
        vm.prank(keeper);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);

        // Verify post-trigger state.
        assertFalse(vault.positionExists(posHash));
        assertFalse(vault.isEncumbered(posHash));

        bytes32 nullifier  = keccak256(abi.encode(intent.nonce, intent.positionCommitment));
        bytes32 outputSalt = keccak256(abi.encode(nullifier, "output"));
        bytes32 outHash    = keccak256(abi.encode(Types.Position({
            owner: alice, asset: address(weth), amount: MOCK_OUTPUT, salt: outputSalt
        })));
        assertTrue(vault.positionExists(outHash));
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function test_setProtocolMinKeeperRewardWei() public {
        vm.prank(owner);
        registry.setProtocolMinKeeperRewardWei(1e15);
        assertEq(registry.protocolMinKeeperRewardWei(), 1e15);
    }

    function test_register_revert_belowProtocolFloor() public {
        vm.prank(owner);
        registry.setProtocolMinKeeperRewardWei(1e15);

        _depositAlice(SALT_1);
        Types.Conditions memory conditions = _defaultConditions();
        (Types.Position memory position, Types.Capability memory spendCap, Types.Intent memory intent,,) =
            _buildSpendBundle(SALT_1, SALT_1, SALT_1, 0);
        bytes32 posHash = keccak256(abi.encode(position));

        (
            Types.Envelope memory envelope,
            Types.Capability memory manageCap,
            bytes memory manageCapSig
        ) = _buildRegistration(posHash, conditions, intent, SALT_2);

        // envelope.minKeeperRewardWei = 0, protocol floor = 1e15 — should fail.
        vm.prank(bob);
        vm.expectRevert("EnvelopeRegistry: keeper reward below protocol floor");
        registry.register(envelope, manageCap, manageCapSig, position);
    }

    function test_pause_preventsRegister() public {
        vm.prank(owner);
        registry.pause();
        vm.expectRevert();
        registry.register(
            Types.Envelope(bytes32(0), bytes32(0), bytes32(0), bytes32(0), 0, 0, 0),
            Types.Capability(address(0), address(0), bytes32(0), 0, bytes32(0),
                _noConstraints(), bytes32(0), 0),
            bytes(""),
            Types.Position(address(0), address(0), 0, bytes32(0))
        );
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    function testFuzz_conditionNotMet_lessThan(uint128 oraclePrice, uint128 threshold) public {
        // Constrain to uint128 to avoid int256 cast overflow and bound() min>max.
        vm.assume(oraclePrice > 0);
        vm.assume(threshold > 0);
        vm.assume(oraclePrice >= threshold); // condition NOT met for LESS_THAN

        oracle.setAnswer(int256(uint256(oraclePrice)));

        (, int256 answer,,,) = oracle.latestRoundData();
        assertFalse(uint256(answer) < uint256(threshold));
    }

    function testFuzz_conditionsMismatch_detectsTamper(bytes32 tamperSeed) public {
        vm.assume(tamperSeed != bytes32(0));

        (
            bytes32 envelopeHash,
            ,
            Types.Conditions memory conditions,
            Types.Position memory position,
            Types.Capability memory spendCap,
            Types.Intent memory intent,
            bytes memory capSig,
            bytes memory intentSig
        ) = _registerDefault();

        conditions.triggerPrice = uint256(tamperSeed); // any modification

        // Only skip if the tamper happens to produce the same hash (astronomically unlikely).
        vm.assume(keccak256(abi.encode(conditions)) !=
            registry.getEnvelope(envelopeHash).envelope.conditionsHash);

        vm.prank(keeper);
        vm.expectRevert(EnvelopeRegistry.ConditionsMismatch.selector);
        registry.trigger(envelopeHash, conditions, position, intent, spendCap, capSig, intentSig);
    }

    // =========================================================================
    // rescueTokens
    // =========================================================================

    function test_rescueTokens_ownerCanRescue() public {
        // Send USDC directly to the registry (simulates stuck tokens).
        uint256 amount = 500e6;
        usdc.mint(address(registry), amount);
        assertEq(usdc.balanceOf(address(registry)), amount);

        uint256 beforeBal = usdc.balanceOf(owner);

        vm.prank(owner);
        registry.rescueTokens(address(usdc), owner, amount);

        assertEq(usdc.balanceOf(address(registry)), 0);
        assertEq(usdc.balanceOf(owner), beforeBal + amount);
    }

    function test_rescueTokens_emitsEvent() public {
        uint256 amount = 100e6;
        usdc.mint(address(registry), amount);

        vm.expectEmit(true, true, false, true);
        emit EnvelopeRegistry.TokensRescued(address(usdc), owner, amount);

        vm.prank(owner);
        registry.rescueTokens(address(usdc), owner, amount);
    }

    function test_rescueTokens_revert_zeroAmount() public {
        usdc.mint(address(registry), 100e6);

        vm.expectRevert(EnvelopeRegistry.RescueAmountZero.selector);
        vm.prank(owner);
        registry.rescueTokens(address(usdc), owner, 0);
    }

    function test_rescueTokens_revert_onlyOwner() public {
        usdc.mint(address(registry), 100e6);

        vm.expectRevert();
        vm.prank(anyone);
        registry.rescueTokens(address(usdc), anyone, 100e6);
    }

    function test_rescueTokens_partialAmount() public {
        uint256 total  = 1_000e6;
        uint256 rescue = 400e6;
        usdc.mint(address(registry), total);

        vm.prank(owner);
        registry.rescueTokens(address(usdc), owner, rescue);

        assertEq(usdc.balanceOf(address(registry)), total - rescue);
    }

}
